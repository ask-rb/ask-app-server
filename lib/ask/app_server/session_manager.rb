# frozen_string_literal: true

module Ask
  module AppServer
    # Manages the lifecycle of agent sessions exposed through the app-server.
    #
    # Orchestrates creation, resumption, subscription, messaging, aborting,
    # and event polling across AgentAdapter instances stored in SessionStore.
    class SessionManager
      # Default tools if none specified.
      DEFAULT_TOOLS = %w[bash read write edit glob grep].freeze

      # Default model if none specified.
      DEFAULT_MODEL = ENV.fetch("ASK_APP_SERVER_MODEL", "gpt-4o")

      attr_reader :store

      def initialize(store: nil)
        @store = store || SessionStore.new
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Create a new session.
      # Returns the session ID.
      def create_session(workspace_path: nil, mode: nil, model: nil, tools: nil, system_prompt: nil)
        adapter = AgentAdapter.new(
          model: model || DEFAULT_MODEL,
          tools: tools || DEFAULT_TOOLS,
          system_prompt: system_prompt || build_default_system_prompt(workspace_path),
          agent_dir: workspace_path
        )

        session_id = adapter.start_session
        @store.add(session_id, adapter)

        @logger.info("Created session #{session_id} (model=#{model || DEFAULT_MODEL})")

        session_id
      end

      # Remove a session.
      def destroy_session(session_id)
        adapter = @store.get(session_id)
        return false unless adapter

        adapter.abort_turn! if adapter.running
        @store.remove(session_id)
        @logger.info("Destroyed session #{session_id}")
        true
      end

      # Get an adapter by session ID.
      def get(session_id)
        @store.get(session_id)
      end

      # List active sessions.
      def list_sessions(limit: 20)
        @store.list(limit: limit)
      end

      # Send a message to a session.
      # If the session is busy, enqueues the message (mid-execution injection).
      # Returns true if the message was accepted.
      def send_message(session_id, content)
        adapter = @store.get(session_id)
        raise SessionNotFound, "Session #{session_id} not found" unless adapter

        if adapter.running
          @logger.info("Session #{session_id} busy, injecting message")
          adapter.inject_message(content)
        else
          adapter.send_message(content)
        end

        true
      end

      # Subscribe to a session's events.
      def subscribe(session_id, delivery_kind: "web-remote-replayable")
        adapter = @store.get(session_id)
        raise SessionNotFound, "Session #{session_id} not found" unless adapter

        @store.subscribe(session_id, delivery_kind: delivery_kind)
        { subscribed: true, sessionId: session_id, deliveryKind: delivery_kind }
      end

      # Get events for a session after a sequence number.
      def get_events(session_id, after_seq:, limit: nil)
        adapter = @store.get(session_id)
        raise SessionNotFound, "Session #{session_id} not found" unless adapter

        events = adapter.events_after(after_seq.to_i)
        events = events.first(limit) if limit && limit > 0

        {
          sessionId: session_id,
          events: events,
          hasMore: limit && limit > 0 && events.length >= limit
        }
      end

      # Read workspace state (model info, tools).
      def read_workspace_state(session_id = nil)
        settings = {
          model: {
            current: {
              modelId: ENV.fetch("ASK_APP_SERVER_MODEL", DEFAULT_MODEL),
              providerId: resolve_provider_id
            }
          }
        }

        if session_id
          adapter = @store.get(session_id)
          if adapter
            settings[:sessionId] = session_id
            settings[:running] = adapter.running
          end
        end

        { settings: settings }
      end

      # Check if a session is subscribed.
      def subscribed?(session_id)
        @store.subscribed?(session_id)
      end

      # Notify subscribers of new events.
      # Called internally; returns events that should be pushed to the subscriber.
      def pending_notifications(session_id)
        adapter = @store.get(session_id)
        return [] unless adapter && subscribed?(session_id)

        adapter.drain_events
      end

      private

      def build_default_system_prompt(workspace_path)
        parts = ["You are a helpful AI coding assistant. You can use shell commands and file operations to help the user."]
        parts << "Working directory: #{workspace_path}" if workspace_path
        parts.join("\n")
      end

      def resolve_provider_id
        model = ENV.fetch("ASK_APP_SERVER_MODEL", DEFAULT_MODEL)
        case model
        when /^gpt/, /^o\d/ then "openai"
        when /^claude/ then "anthropic"
        when /^gemini/ then "google"
        else "openai"
        end
      end
    end
  end
end
