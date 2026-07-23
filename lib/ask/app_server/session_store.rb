# frozen_string_literal: true

require "json"

module Ask
  module AppServer
    # In-memory session store for the app-server.
    #
    # Manages agent adapters, subscriptions, and event history.
    # Thread-safe: all access is mutex-guarded.
    #
    # Future: can be backed by SQLite for cross-process session sharing
    # (like ZCode's ~/.zcode/cli/db/db.sqlite).
    class SessionStore
      def initialize
        @sessions = {}   # session_id => AgentAdapter
        @subscriptions = {}  # session_id => { subscribed: bool, delivery_kind: string }
        @mutex = Mutex.new
      end

      # Register a new session.
      def add(session_id, adapter)
        @mutex.synchronize do
          raise SessionAlreadyExists, "Session #{session_id} already exists" if @sessions.key?(session_id)
          @sessions[session_id] = adapter
          @subscriptions[session_id] = { subscribed: false, delivery_kind: nil }
        end
      end

      # Remove a session.
      def remove(session_id)
        @mutex.synchronize do
          @sessions.delete(session_id)
          @subscriptions.delete(session_id)
        end
      end

      # Get a session adapter by ID.
      def get(session_id)
        @mutex.synchronize { @sessions[session_id] }
      end

      # List all sessions (summaries).
      def list(limit: 20)
        @mutex.synchronize do
          @sessions.values.first(limit).map do |adapter|
            {
              sessionId: adapter.session_id,
              createdAt: adapter.created_at.iso8601,
              running: adapter.running,
              idle: adapter.idle?
            }
          end
        end
      end

      # Subscribe to a session's events.
      def subscribe(session_id, delivery_kind:)
        @mutex.synchronize do
          raise SessionNotFound, "Session #{session_id} not found" unless @sessions.key?(session_id)
          @subscriptions[session_id] = { subscribed: true, delivery_kind: delivery_kind }
        end
      end

      # Unsubscribe from a session.
      def unsubscribe(session_id)
        @mutex.synchronize do
          @subscriptions[session_id] = { subscribed: false, delivery_kind: nil } if @subscriptions.key?(session_id)
        end
      end

      # Is the session subscribed?
      def subscribed?(session_id)
        @mutex.synchronize do
          sub = @subscriptions[session_id]
          sub && sub[:subscribed]
        end
      end

      # Count of active sessions.
      def count
        @mutex.synchronize { @sessions.size }
      end

      # Clear all sessions.
      def clear
        @mutex.synchronize do
          @sessions.clear
          @subscriptions.clear
        end
      end

      # Iterate over all session adapters.
      def each(&block)
        @mutex.synchronize do
          @sessions.each_value(&block)
        end
      end
    end
  end
end
