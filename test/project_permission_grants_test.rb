# frozen_string_literal: true

require_relative "test_helper"

class ProjectPermissionGrantsTest < Minitest::Test
  class State
    def initialize
      @values = {}
    end

    def get(key) = @values[key]
    def set(key, value, ttl: nil) = @values[key] = value
  end

  # Lock-capable state double (the Ask::State::Adapter contract):
  # records the order of operations so tests can prove the distributed
  # lock spans each read-modify-write mutation.
  class LockState
    Token = Struct.new(:token)

    attr_reader :events

    def initialize
      @values = {}
      @events = []
      @held = false
    end

    def get(key)
      @events << :get
      @values[key]
    end

    def set(key, value, ttl: nil)
      @events << :set
      @values[key] = value
    end

    def acquire_lock(_key, ttl: 10)
      return nil if @held

      @held = true
      @events << :acquire
      Token.new("tok-#{@events.size}")
    end

    def release_lock(_key, _lock)
      @events << :release
      @held = false
      true
    end
  end

  # The lock is contended the first +contend+ attempts (acquire returns
  # nil), then granted — mutations must retry instead of giving up.
  class ContendedLockState < LockState
    def initialize(contend: 2)
      super()
      @contend = contend
    end

    def acquire_lock(key, ttl: 10)
      if @contend.positive?
        @contend -= 1
        @events << :acquire_miss
        return nil
      end

      super
    end
  end

  # The lock can never be acquired (every holder holds it forever):
  # mutations must fail closed instead of writing outside the lock.
  class LockedOutState < LockState
    def acquire_lock(_key, ttl: 10)
      @events << :acquire_miss
      nil
    end
  end

  # Shared backend that widens the lost-update window: a write waits
  # (briefly) for a concurrent writer. Two unsynchronized
  # read-modify-write cycles therefore always overlap — both read the
  # pre-write value, and the second write erases the first. A caller
  # holding the state-provider lock never sees a concurrent writer
  # (the peer cannot enter), so serialized mutations pass.
  class RacingState
    WRITER_WINDOW = 0.25

    def initialize
      @values = {}
      @sync = Mutex.new
      @cond = ConditionVariable.new
      @writers = 0
      @overlap = false
      @lock_held = false
    end

    def get(key)
      @sync.synchronize { @values[key] }
    end

    def set(key, value, ttl: nil)
      @sync.synchronize do
        @writers += 1
        if @writers >= 2
          @overlap = true
          @cond.broadcast
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WRITER_WINDOW
          until @overlap
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @cond.wait(@sync, remaining)
          end
        end
        @values[key] = value
        @writers -= 1
      end
    end

    def acquire_lock(_key, ttl: 10)
      @sync.synchronize do
        return nil if @lock_held

        @lock_held = true
        "token"
      end
    end

    def release_lock(_key, _lock)
      @sync.synchronize do
        @lock_held = false
        true
      end
    end
  end

  def test_grants_are_persisted_and_shared_by_workspace_identity
    state = State.new
    first = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")
    first.grant("bash")

    resumed = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    assert resumed.granted?("bash")
    assert_equal({ version: 1, granted_tools: ["bash"] }, resumed.snapshot)
  end

  def test_grants_are_isolated_by_workspace_identity
    state = State.new
    Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1").grant("bash")
    other = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-2")

    refute other.granted?("bash")
  end

  def test_revoke_removes_only_the_selected_tool
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: State.new, project_id: "workspace-1")
    grants.grant("bash")
    grants.grant("write")

    grants.revoke("bash")

    refute grants.granted?("bash")
    assert grants.granted?("write")
  end

  def test_invalid_project_identity_is_rejected
    assert_raises(ArgumentError) do
      Ask::AppServer::ProjectPermissionGrants.new(state: State.new, project_id: " ")
    end
  end

  # ── Cross-process safety: the state provider's lock ────────────────────

  def test_mutation_holds_the_state_provider_lock_across_read_and_write
    state = LockState.new
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    assert grants.grant("bash")

    assert_equal %i[acquire get set release], state.events,
                 "the provider lock must span the whole read-modify-write cycle"
  end

  def test_remutation_revoke_also_holds_the_provider_lock
    state = LockState.new
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")
    grants.grant("bash")
    state.events.clear

    assert grants.revoke("bash")

    assert_equal %i[acquire get set release], state.events
  end

  def test_contended_lock_is_retried_until_acquired
    state = ContendedLockState.new(contend: 2)
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    assert grants.grant("bash")
    assert grants.granted?("bash")
    assert_equal 2, state.events.count(:acquire_miss), "both contended attempts missed"
    assert_equal 1, state.events.count(:acquire), "the retry finally acquired"
    assert_equal 1, state.events.count(:set), "exactly one write, under the lock"
  end

  def test_lock_timeout_fails_closed_instead_of_writing_outside_the_lock
    state = LockedOutState.new
    grants = Ask::AppServer::ProjectPermissionGrants.new(
      state: state, project_id: "workspace-1", lock_timeout: 0.05
    )

    error = assert_raises(Ask::AppServer::Error) { grants.grant("bash") }
    assert_match(/lock/i, error.message)
    refute_includes state.events, :set, "never write outside the lock"

    # Reads stay available and unchanged while writes fail closed.
    refute grants.granted?("bash")
    assert_equal({ version: 1, granted_tools: [] }, grants.snapshot)
  end

  def test_state_without_lock_support_falls_back_to_local_synchronization
    # State implements only get/set (no acquire_lock): the documented
    # single-process fallback — adapters without lock support keep
    # working rather than raising at construction time.
    state = State.new
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    assert grants.grant("bash")
    assert grants.granted?("bash")
    assert grants.revoke("bash")
    refute grants.granted?("bash")
  end

  def test_concurrent_grants_from_separate_instances_do_not_lose_updates
    state = RacingState.new
    first = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")
    second = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    start = Queue.new
    threads = [
      Thread.new { start.pop; first.grant("bash") },
      Thread.new { start.pop; second.grant("write") }
    ]
    2.times { start << true }
    threads.each(&:join)

    assert first.granted?("bash"), "the first instance's grant was lost to a racing writer"
    assert first.granted?("write"), "the second instance's grant was lost to a racing writer"
    assert_equal({ version: 1, granted_tools: %w[bash write] }, first.snapshot)
  end
end
