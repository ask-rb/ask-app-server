# frozen_string_literal: true

require "json"

module Ask
  module AppServer
    # Session store backed by Ask::State::Adapter.
    #
    # Stores session metadata and subscriptions in the state backend.
    # AgentAdapter instances (which hold in-memory agent sessions) are
    # kept separately and not persisted.
    #
    # Default backend is Ask::State::Memory (in-process, ephemeral).
    # Pass Ask::State::Providers::SQLite for persistent storage:
    #
    #   store = SessionStore.new(
    #     state: Ask::State::Providers::SQLite.new(path: "~/.ask-app-server/state.db")
    #   )
    class SessionStore
      SESSION_PREFIX = "session:"
      SUBSCRIPTION_PREFIX = "sub:"
      SESSION_LIST_KEY = "sessions"
      EVENT_PREFIX = "events:"

      def initialize(state: nil)
        @state = state || Ask::State::Memory.new
        @adapters = {}   # session_id => AgentAdapter (in-memory only)
        @mutex = Mutex.new
      end

      # Register a new session.
      def add(session_id, adapter)
        model = adapter.respond_to?(:instance_variable_get) ? adapter.instance_variable_get(:@model) : nil
        metadata = {
          sessionId: session_id,
          model: model,
          createdAt: adapter.respond_to?(:created_at) ? adapter.created_at.iso8601 : Time.now.iso8601
        }

        @mutex.synchronize do
          existing = @state.get("#{SESSION_PREFIX}#{session_id}")
          raise Ask::AppServer::SessionAlreadyExists, "Session #{session_id} already exists" if existing

          @state.set("#{SESSION_PREFIX}#{session_id}", metadata)
          @state.list_append(SESSION_LIST_KEY, session_id, max_length: 200)
          @adapters[session_id] = adapter
        end
      end

      # Remove a session.
      def remove(session_id)
        @mutex.synchronize do
          _remove(session_id)
        end
      end

      # Internal remove (no locking — caller must hold @mutex).
      def _remove(session_id)
        @state.delete("#{SESSION_PREFIX}#{session_id}")
        @state.delete("#{SUBSCRIPTION_PREFIX}#{session_id}")
        @state.delete("#{EVENT_PREFIX}#{session_id}")
        @adapters.delete(session_id)
      end

      # Get a session adapter by ID.
      def get(session_id)
        @mutex.synchronize { @adapters[session_id] }
      end

      # List all sessions (summaries).
      def list(limit: 20)
        session_ids = @state.list_range(SESSION_LIST_KEY, 0, limit - 1)
        session_ids.map do |sid|
          metadata = @state.get("#{SESSION_PREFIX}#{sid}")
          if metadata
            adapter = @adapters[sid]
            metadata.merge(
              running: adapter&.running || false,
              idle: adapter&.idle? || true
            )
          end
        end.compact
      end

      # Subscribe to a session's events.
      def subscribe(session_id, delivery_kind:)
        @mutex.synchronize do
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless @adapters.key?(session_id)
          @state.set("#{SUBSCRIPTION_PREFIX}#{session_id}", { subscribed: true, deliveryKind: delivery_kind })
        end
      end

      # Unsubscribe from a session.
      def unsubscribe(session_id)
        @mutex.synchronize do
          @state.delete("#{SUBSCRIPTION_PREFIX}#{session_id}")
        end
      end

      # Is the session subscribed?
      def subscribed?(session_id)
        sub = @state.get("#{SUBSCRIPTION_PREFIX}#{session_id}")
        sub && sub[:subscribed]
      end

      # Count of active sessions.
      def count
        @adapters.size
      end

      # Clear all sessions.
      def clear
        @mutex.synchronize do
          @adapters.each_key { |sid| _remove(sid) }
        end
      end

      # Iterate over all session adapters.
      def each(&block)
        # Iterate over a snapshot to avoid holding the mutex during yield
        snapshot = @mutex.synchronize { @adapters.values.dup }
        snapshot.each(&block)
      end

      # Append an event to a session's event log.
      def append_event(session_id, event)
        @state.list_append("#{EVENT_PREFIX}#{session_id}", event, max_length: 1000)
      end

      # Get events for a session after a given sequence number.
      def events_after(session_id, after_seq, limit: nil)
        events = @state.list_range("#{EVENT_PREFIX}#{session_id}") || []
        filtered = events.select { |e| e[:seq].to_i > after_seq.to_i }
        limit ? filtered.first(limit) : filtered
      end
    end
  end
end
