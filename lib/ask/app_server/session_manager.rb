# frozen_string_literal: true

module Ask
  module AppServer
    # Manages the lifecycle of agent sessions exposed through the session
    # host (ask-app-server).
    #
    # Orchestrates creation, resumption, subscription, messaging, aborting,
    # interaction resolution (approvals, plan), closing, and event polling
    # across AgentAdapter instances stored in SessionStore.
    class SessionManager
      # Default tools if none specified.
      DEFAULT_TOOLS = %w[bash read write edit glob grep].freeze

      # Default model if none specified.
      DEFAULT_MODEL = ENV.fetch("ASK_APP_SERVER_MODEL", "opencode_go/deepseek-v4-flash")

      # Tools gated behind human approval when approval is :require.
      DEFAULT_REQUIRE_APPROVAL = %w[write edit bash destroy].freeze

      attr_reader :store
      attr_reader :permission_mode
      attr_reader :blocked_tools
      attr_reader :permission_timeout

      def initialize(store: nil, permission_mode: :on_request, blocked_tools: nil, permission_timeout: 300)
        @store = store || SessionStore.new
        @permission_mode = permission_mode
        @blocked_tools = (blocked_tools || DEFAULT_REQUIRE_APPROVAL).map(&:to_s)
        @permission_timeout = permission_timeout
        @session_event_observers = []
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG || Logger::DEBUG : Logger::WARN)
      end

      # Register an observer for canonical events across all sessions.
      # Called with (session_id, Ask::SessionProtocol::Events::Event) for
      # every emitted event, as it happens.
      def on_session_event(&block)
        @session_event_observers << block
      end

      # Set the permission mode for new sessions (:on_request, :never, :auto).
      def permission_mode=(mode)
        @permission_mode = mode.to_sym
      end

      # The approval mode new sessions get, translated to the canonical
      # vocabulary (:off, :require, :auto).
      def approval_mode
        translate_permission_mode(@permission_mode)
      end

      # Create a new session.
      # Returns the session ID.
      #
      # @param mode [String, Symbol, nil] "on_request"/"build"/"edit"
      #   (approvals required for blocked tools), "auto", "never"/"off"/"yolo"
      #   (no approvals), "plan" (plan mode, read-only until approved); nil
      #   falls back to the manager's permission_mode
      def create_session(workspace_path: nil, mode: nil, model: nil, tools: nil, system_prompt: nil)
        approval_opts, plan_mode = resolve_approval(mode)

        # Extract provider prefix from model string (e.g., "opencode_go/deepseek-v4-flash")
        model_id, model_provider = parse_model_string(model || DEFAULT_MODEL)
        model_for_agent = model_provider ? model_id : (model || DEFAULT_MODEL)

        adapter = AgentAdapter.new(
          model: model_for_agent,
          tools: tools || DEFAULT_TOOLS,
          system_prompt: system_prompt || build_default_system_prompt(workspace_path),
          agent_dir: workspace_path,
          approval: approval_opts[:mode],
          require_approval: approval_opts[:require_approval],
          plan_mode: plan_mode
        )

        session_id = adapter.start_session
        @store.add(session_id, adapter)

        # Attach observers after registration so they see a settled store
        # (e.g. the pane reporter's session-count metadata), then replay
        # the session.created event the adapter buffered during start.
        adapter.on_event { |event| notify_session_event(adapter.session_id, event) }
        created = adapter.pending_events.find { |e| e.type == "session.created" }
        notify_session_event(session_id, created) if created

        @logger.info("Created session #{session_id} (model=#{model || DEFAULT_MODEL}, approval=#{approval_opts[:mode]})")

        session_id
      end

      # Remove a session.
      def destroy_session(session_id)
        adapter = @store.get(session_id)
        return false unless adapter

        adapter.abort_turn! if adapter.running
        adapter.close!
        @store.remove(session_id)
        @logger.info("Destroyed session #{session_id}")
        true
      end

      # Close a session (protocol alias of destroy_session).
      def close_session(session_id)
        destroy_session(session_id)
      end

      # Get an adapter by session ID.
      def get(session_id)
        @store.get(session_id)
      end

      # List active sessions.
      def list_sessions(limit: 20)
        @store.list(limit: limit)
      end

      # Send a message to a session (prompt when idle, mid-execution
      # injection when running).
      #
      # @return [Hash] { accepted: Boolean, status: "steered"|"queued"|"stale", turnId: }
      def send_message(session_id, content, expected_turn_id: nil)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        result = adapter.send_message(content, expected_turn_id: expected_turn_id)
        {
          accepted: result[:status] != "stale",
          status: result[:status],
          turnId: result[:turn_id]
        }
      end

      # ── Interactions (approvals) ───────────────────────────────────────

      # Pending approval interactions for a session.
      def pending_interactions(session_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.pending_interactions
      end

      # Approve a pending approval interaction by canonical id.
      # @return [Boolean]
      def approve_interaction(session_id, interaction_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.approve_interaction(interaction_id)
      end

      # Reject a pending approval interaction by canonical id.
      # @return [Boolean]
      def reject_interaction(session_id, interaction_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.reject_interaction(interaction_id)
      end

      # Approve every pending approval interaction.
      # @return [Integer] number approved
      def approve_all_interactions(session_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.approve_all_interactions
      end

      # Reject every pending approval interaction.
      # @return [Integer] number rejected
      def reject_all_interactions(session_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.reject_all_interactions
      end

      # ── Plan mode ───────────────────────────────────────────────────────

      # Approve the pending plan proposal.
      # @return [Boolean]
      def plan_approve(session_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.plan_approve
      end

      # Reject the pending plan proposal; the agent stays in plan mode.
      # @return [Boolean]
      def plan_reject(session_id)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        adapter.plan_reject
      end

      # ── Events and workspace ───────────────────────────────────────────

      # Subscribe to a session's events.
      def subscribe(session_id, delivery_kind: "replay")
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        @store.subscribe(session_id, delivery_kind: delivery_kind)
        { subscription: { sessionId: session_id, deliveryKind: delivery_kind } }
      end

      # Get events for a session after a sequence number.
      def get_events(session_id, after_seq:, limit: nil)
        adapter = @store.get(session_id)
        raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

        events = adapter.events_after(after_seq.to_i)
        events = events.first(limit) if limit && limit > 0

        {
          sessionId: session_id,
          events: events,
          hasMore: limit && limit > 0 && events.length >= limit
        }
      end

      # Read workspace state.
      def read_workspace_state(session_id = nil)
        workspace = {
          path: nil,
          name: nil,
          gitBranch: nil,
          mode: approval_mode.to_s
        }

        if session_id
          adapter = @store.get(session_id)
          if adapter
            workspace[:sessionId] = session_id
            workspace[:running] = adapter.running
          end
        end

        settings = {
          model: {
            current: {
              modelId: ENV.fetch("ASK_APP_SERVER_MODEL", DEFAULT_MODEL),
              providerId: resolve_provider_id
            }
          },
          permissions: {
            mode: @permission_mode.to_s
          }
        }

        { workspace: workspace, settings: settings }
      end

      # Check if a session is subscribed.
      def subscribed?(session_id)
        @store.subscribed?(session_id)
      end

      private

      # Resolve the session mode into approval options + plan mode.
      #
      # @return [Array(Hash, Boolean)] [{ mode:, require_approval: }, plan_mode]
      def resolve_approval(mode)
        plan_mode = false
        approval_mode =
          case mode.to_s
          when "plan" then plan_mode = true; :off
          when "yolo", "never", "off" then :off
          when "build", "edit", "on_request" then :require
          when "auto" then :auto
          else translate_permission_mode(@permission_mode)
          end

        opts = { mode: approval_mode }
        opts[:require_approval] = @blocked_tools if approval_mode == :require
        [opts, plan_mode]
      end

      def translate_permission_mode(mode)
        case mode.to_s
        when "never", "off", "yolo" then :off
        when "auto" then :auto
        else :require
        end
      end

      def notify_session_event(session_id, event)
        @session_event_observers.each { |observer| observer.call(session_id, event) }
      end

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

      # Parse a model string that may include a provider prefix.
      # "opencode_go/deepseek-v4-flash" => ["deepseek-v4-flash", "opencode_go"]
      # "gpt-4o" => ["gpt-4o", nil]
      def parse_model_string(str)
        return [str, nil] unless str&.include?("/")
        parts = str.split("/", 2)
        [parts[1], parts[0]]
      end
    end
  end
end
