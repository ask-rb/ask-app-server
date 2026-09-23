# frozen_string_literal: true

require "digest"

module Ask
  module AppServer
    # Persistent tool grants scoped to one canonical workspace identity.
    # Storage is owned by the host and supplied through ask-state-providers.
    #
    # grant/revoke are read-modify-write cycles. A local Mutex only
    # serializes callers inside one process; two app-server processes
    # sharing a SQLite/Postgres/Redis/MySQL backend interleave their
    # get→set cycles and lose each other's updates (a revoked grant
    # silently surviving, or a grant never persisting). The
    # Ask::State::Adapter contract's distributed lock
    # (`acquire_lock`/`release_lock` — token-safe on every shipped
    # backend) is therefore held across each mutation whenever the
    # supplied adapter implements it.
    #
    # Adapters without lock support keep working: mutations fall back
    # to the local Mutex alone, which is single-process safe only —
    # cross-process deployments must use a contract-conforming state
    # adapter. If the lock cannot be acquired within the timeout the
    # mutation fails closed (raises) rather than writing outside the
    # lock.
    class ProjectPermissionGrants
      SNAPSHOT_VERSION = 1

      # How long one mutation may hold the state-provider lock. The
      # critical section is a get plus a set — milliseconds; the TTL is
      # only a stale-lock backstop.
      LOCK_TTL = 10

      # How long a contended mutation waits for the provider lock before
      # failing closed.
      LOCK_TIMEOUT = 2.0

      # Pause between acquire attempts while contended.
      LOCK_RETRY_INTERVAL = 0.005

      attr_reader :project_id

      def initialize(state:, project_id:, lock_timeout: LOCK_TIMEOUT)
        normalized = project_id.to_s.strip
        raise ArgumentError, "project_id must not be blank" if normalized.empty?
        raise ArgumentError, "state must respond to get and set" unless state.respond_to?(:get) && state.respond_to?(:set)

        @state = state
        @project_id = normalized
        @key = "ask-app-server:project-permission-grants:#{Digest::SHA256.hexdigest(normalized)}"
        @lock_key = "#{@key}:lock"
        @lock_timeout = lock_timeout
        @mutex = Mutex.new
        @distributed_lock = state.respond_to?(:acquire_lock) && state.respond_to?(:release_lock)
      end

      def granted?(tool_name)
        name = normalize_tool_name(tool_name)
        read_tools.include?(name)
      end

      def grant(tool_name)
        name = normalize_tool_name(tool_name)
        with_mutation_lock do
          tools = read_tools
          next false if tools.include?(name)

          write_tools(tools + [name])
          true
        end
      end

      def revoke(tool_name)
        name = normalize_tool_name(tool_name)
        with_mutation_lock do
          tools = read_tools
          next false unless tools.include?(name)

          write_tools(tools - [name])
          true
        end
      end

      def snapshot
        { version: SNAPSHOT_VERSION, granted_tools: read_tools }
      end

      private

      # Run one read-modify-write mutation under exclusive access. With
      # a contract-conforming adapter that is the state provider's
      # distributed lock (shared by every process on the backend);
      # otherwise the local Mutex (single-process only — see the class
      # comment). Returns the block's value.
      def with_mutation_lock
        return @mutex.synchronize { yield } unless @distributed_lock

        lock = acquire_state_lock!
        begin
          yield
        ensure
          @state.release_lock(@lock_key, lock)
        end
      end

      # Acquire the provider lock, retrying while a peer holds it.
      # Raises (fail closed) instead of proceeding unlocked when the
      # contention outlasts the timeout.
      def acquire_state_lock!
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
        loop do
          lock = @state.acquire_lock(@lock_key, ttl: LOCK_TTL)
          return lock if lock

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise Ask::AppServer::Error,
                  "Timed out acquiring the project permission grant lock after #{@lock_timeout}s"
          end

          sleep LOCK_RETRY_INTERVAL
        end
      end

      def normalize_tool_name(tool_name)
        name = tool_name.to_s.strip
        raise ArgumentError, "tool_name must not be blank" if name.empty?

        name
      end

      # Reads are a single atomic get on every backend — they stay
      # lock-free (and available even when a mutation is failing closed
      # on lock contention).
      def read_tools
        stored = @state.get(@key)
        return [] if stored.nil?

        version = stored[:version] || stored["version"] if stored.is_a?(Hash)
        tools = stored[:granted_tools] || stored["granted_tools"] if stored.is_a?(Hash)
        unless version == SNAPSHOT_VERSION && tools.is_a?(Array) && tools.all? { |name| name.is_a?(String) && !name.empty? }
          raise Ask::AppServer::Error, "Stored project permission grants are malformed"
        end

        tools.uniq
      end

      def write_tools(tools)
        @state.set(@key, { version: SNAPSHOT_VERSION, granted_tools: tools.sort })
      end
    end
  end
end
