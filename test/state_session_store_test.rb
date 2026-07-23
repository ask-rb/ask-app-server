# frozen_string_literal: true

require_relative "test_helper"

class StateSessionStoreTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    # Use in-memory state for the test (no SQLite dependency in tests)
    @state = Ask::State::Memory.new
    @store = Ask::AppServer::SessionStore.new(state: @state)
    @adapter = stub("adapter",
      session_id: "sid-1",
      created_at: Time.now,
      running: false,
      idle?: true,
      instance_variable_get: nil
    )
  end

  def test_add_and_get
    @store.add("sid-1", @adapter)
    assert_equal @adapter, @store.get("sid-1")
  end

  def test_add_duplicate_raises
    @store.add("sid-1", @adapter)
    assert_raises(Ask::AppServer::SessionAlreadyExists) do
      @store.add("sid-1", @adapter)
    end
  end

  def test_remove
    @store.add("sid-1", @adapter)
    @store.remove("sid-1")
    assert_nil @store.get("sid-1")
  end

  def test_list
    adapter2 = stub("adapter2",
      session_id: "sid-2",
      created_at: Time.now,
      running: false,
      idle?: true,
      instance_variable_get: nil
    )

    @store.add("sid-1", @adapter)
    @store.add("sid-2", adapter2)

    list = @store.list
    assert_equal 2, list.length
    assert list.any? { |s| s[:sessionId] == "sid-1" }
    assert list.any? { |s| s[:sessionId] == "sid-2" }
  end

  def test_subscribe_and_unsubscribe
    @store.add("sid-1", @adapter)

    refute @store.subscribed?("sid-1")

    @store.subscribe("sid-1", delivery_kind: "test")
    assert @store.subscribed?("sid-1")

    @store.unsubscribe("sid-1")
    refute @store.subscribed?("sid-1")
  end

  def test_subscribe_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @store.subscribe("nonexistent", delivery_kind: "test")
    end
  end

  def test_count
    @store.add("sid-1", @adapter)
    assert_equal 1, @store.count
  end

  def test_clear
    @store.add("sid-1", @adapter)
    @store.clear
    assert_equal 0, @store.count
  end

  def test_each
    @store.add("sid-1", @adapter)
    found = []
    @store.each { |a| found << a }
    assert_equal [@adapter], found
  end

  def test_events_persist_in_state
    @store.add("sid-1", @adapter)

    @store.append_event("sid-1", { type: "turn.started", seq: 1 })
    @store.append_event("sid-1", { type: "model.streaming", seq: 2, payload: { delta: "Hello" } })

    events = @store.events_after("sid-1", 0)
    assert_equal 2, events.length
    assert_equal "turn.started", events[0][:type]

    events_after_1 = @store.events_after("sid-1", 1)
    assert_equal 1, events_after_1.length
    assert_equal "model.streaming", events_after_1[0][:type]
  end

  def test_sqlite_persistence
    begin
      require "sqlite3"
      require "ask/state/providers/sqlite"
    rescue LoadError
      skip "sqlite3 gem not available in test environment"
    end

    with_tempdir do |dir|
      db_path = File.join(dir, "test_state.db")

      state = Ask::State::Providers::SQLite.new(path: db_path)
      store = Ask::AppServer::SessionStore.new(state: state)

      adapter = stub("persistent-adapter",
        session_id: "persistent-1",
        created_at: Time.now,
        running: false,
        idle?: true,
        instance_variable_get: nil
      )

      store.add("persistent-1", adapter)
      store.subscribe("persistent-1", delivery_kind: "test")

      # Create a new store with the same SQLite database
      state2 = Ask::State::Providers::SQLite.new(path: db_path)
      store2 = Ask::AppServer::SessionStore.new(state: state2)

      # The session metadata is persistent but adapters are in-memory,
      # so the adapter won't be in the new store
      assert_nil store2.get("persistent-1"), "adapters don't survive restarts"

      state.close
      state2.close
    end
  end
end
