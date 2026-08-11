# frozen_string_literal: true

module Ask
  module AppServer
    # Wraps an Ask::Agent::Session and translates its events into canonical
    # Ask::SessionProtocol events via EventTranslator.
    #
    # Each wrapper is associated with one session and maintains an
    # EventTranslator that clients poll or subscribe to. The adapter also
    # owns the approval queue wiring (approval events surface as
    # approval.required / approval.updated) and the interaction controls
    # (approve/reject by id, plan approve/reject) that any client can call.
    class AgentAdapter
      # The underlying ask-agent session.
      attr_reader :session

      # The event translator that accumulates protocol events.
      attr_reader :translator

      # The session ID (same as ask-agent session id).
      attr_reader :session_id

      # Whether a turn is currently in progress.
      attr_reader :running

      # When the session was created.
      attr_reader :created_at

      # @param model [String] model identifier
      # @param tools [Array<String, Class>] tool names or classes
      # @param system_prompt [String, nil]
      # @param agent_dir [String, nil] workspace path
      # @param approval [Symbol] :off, :require, or :auto
      # @param require_approval [Array<String>, nil] tool names gated behind
      #   human approval when approval is :require
      # @param session_opts [Hash] remaining options passed to
      #   Ask::Agent::Session.new (hooks, plan_mode, todos, ...)
      def initialize(model:, tools: nil, system_prompt: nil, agent_dir: nil,
                     approval: :off, require_approval: nil, **session_opts)
        @model = model
        @system_prompt = system_prompt
        @tools = resolve_tools(tools)
        @session_opts = session_opts
        @approval = approval
        @require_approval = require_approval
        @agent_dir = agent_dir
        @session = nil
        @translator = nil
        @on_event_block = nil
        @session_id = nil
        @running = false
        @running_mutex = Mutex.new
        @run_thread = nil
        @abort_requested = false
        @created_at = Time.now
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Start a new ask-agent session.
      # Returns the session ID.
      def start_session
        @translator = EventTranslator.new
        @translator.on_event = @on_event_block if @on_event_block
        @session = build_session
        @session_id = @session.id
        @session.on_event { |event| handle_agent_event(event) }
        @translator.session_created(@session_id)
        @session_id
      end

      # Resume an existing session (re-attach event handler).
      def resume(session)
        @session = session
        @session_id = session.id
        @translator = EventTranslator.new
        @translator.on_event = @on_event_block if @on_event_block
        @session.on_event { |event| handle_agent_event(event) }
        @session_id
      end

      # Register an observer for every canonical event this session emits
      # (translations plus approval/plan/session-lifecycle emissions).
      # May be called before start_session; the block is applied when the
      # translator exists so the observer sees session.created.
      def on_event(&block)
        if @translator
          @translator.on_event = block
        else
          @on_event_block = block
        end
      end

      # Send a message and start processing (idle session) or inject it
      # mid-run (running session). Uses ask-agent's steer semantics:
      #
      #   steered — the message was added to the conversation immediately
      #   queued  — the session is running; the message is queued for the
      #             next turn boundary (no abort)
      #   stale   — the caller's expected_turn_id no longer matches
      #
      # @param content [String]
      # @param expected_turn_id [String, nil] staleness guard
      # @return [Hash] { status: "steered"|"queued"|"stale", turn_id: }
      def send_message(content, expected_turn_id: nil)
        raise "Session not started" unless @session

        if @running
          result = @session.steer(content, expected_turn_id: expected_turn_id)
          { status: result[:status].to_s, turn_id: result[:turn_id] }
        else
          start_run(content)
          { status: "steered", turn_id: @session.turn_id }
        end
      end

      # Request abort of the current turn.
      def abort_turn!
        @abort_requested = true
        @session&.abort if @session
      end

      # Wait for the current turn to complete (with timeout).
      # Returns true if completed, false if timed out.
      def wait_for_turn(timeout: 600)
        thread = @run_thread
        return true unless thread

        thread.join(timeout)
        !thread.alive?
      end

      # Whether this session is idle (no turn running).
      def idle?
        !@running
      end

      # ── Interactions (approvals) ───────────────────────────────────────

      # Pending approval interactions, as canonical Interaction objects.
      def pending_interactions
        queue = @session&.approval_queue
        return [] unless queue

        queue.pending_actions.map do |action|
          payload = { "toolName" => action.tool_name.to_s }
          payload["args"] = action.args if action.args
          payload["message"] = action.message if action.message
          payload["autoApprovable"] = action.auto_approvable unless action.auto_approvable.nil?
          Ask::SessionProtocol::Interactions.interaction(
            id: "act_#{action.id}", kind: "approval", status: "pending", payload: payload
          )
        end
      end

      # Approve a pending approval interaction by canonical id ("act_N").
      # @return [Boolean] whether an action was approved
      def approve_interaction(interaction_id)
        apply_interaction(interaction_id) { |queue, id| queue.approve(id) }
      end

      # Reject a pending approval interaction by canonical id ("act_N").
      # @return [Boolean] whether an action was rejected
      def reject_interaction(interaction_id)
        apply_interaction(interaction_id) { |queue, id| queue.reject(id) }
      end

      # Approve every pending approval interaction.
      # @return [Integer] number approved
      def approve_all_interactions
        queue = @session&.approval_queue
        return 0 unless queue

        queue.approve_all.size
      end

      # Reject every pending approval interaction.
      # @return [Integer] number rejected
      def reject_all_interactions
        queue = @session&.approval_queue
        return 0 unless queue

        queue.reject_all.size
      end

      # ── Plan mode ───────────────────────────────────────────────────────

      # Approve the pending plan proposal.
      # @return [Boolean]
      def plan_approve
        queue = @session&.plan_queue
        return false unless queue

        queue.approve_all.any?
      end

      # Reject the pending plan proposal; the agent stays in plan mode.
      # @return [Boolean]
      def plan_reject
        queue = @session&.plan_queue
        return false unless queue

        queue.reject_all.any?
      end

      # ── Lifecycle ───────────────────────────────────────────────────────

      # Close the session: delete its state and emit session.ended.
      def close!
        @session&.delete if @session.respond_to?(:delete)
        @translator&.session_ended(@session_id, reason: "closed")
        true
      end

      # The accumulated streaming text from the current/last turn.
      def streaming_text
        @translator&.instance_variable_get(:@streaming_text).to_s
      end

      # All events since last drain.
      def pending_events
        @translator&.pending_events || []
      end

      # Drain and return pending events.
      def drain_events
        @translator&.drain_events || []
      end

      # Last sequence number.
      def last_seq
        @translator&.last_seq || 0
      end

      # Events after a given sequence number.
      def events_after(after_seq)
        pending_events.select { |e| e.seq > after_seq }
      end

      private

      def build_session
        opts = @session_opts.dup
        hooks = opts.delete(:hooks) || {}
        approval_option = build_approval_option
        opts[:approval] = approval_option if approval_option
        opts[:plan_mode] = false unless opts.key?(:plan_mode)

        Ask::Agent::Session.new(
          model: @model,
          tools: @tools,
          system_prompt: @system_prompt,
          agent_dir: @agent_dir,
          hooks: hooks,
          **opts
        )
      end

      # Build the approval option for Ask::Agent::Session: an
      # EmittingApprovalQueue whose events stream to the translator.
      def build_approval_option
        return nil if @approval == :off

        queue = EmittingApprovalQueue.new(
          on_submit: ->(action) { @translator.approval_required(action) },
          on_status: ->(action) { @translator.approval_updated(action) }
        )
        return { queue: queue } if @approval == :auto

        { queue: queue, require_approval: @require_approval }
      end

      def apply_interaction(interaction_id)
        id = interaction_id.to_s[/\Aact_(\d+)\z/, 1]
        return false unless id

        queue = @session&.approval_queue
        return false unless queue

        yield(queue, id.to_i).any?
      end

      def start_run(content)
        @running_mutex.synchronize do
          @abort_requested = false
          @running = true
        end

        @run_thread = Thread.new do
          begin
            @session.run(content, reset: false)
            # Drain steers queued while the turn was running (mid-execution
            # injection): each subsequent run processes one queued message.
            while @session.queued_steers.positive?
              @session.run("", reset: false)
            end
          rescue => e
            # Agent may have been aborted — that's fine
            @logger.debug("Agent run error: #{e.message}") if ENV["DEBUG"]
          ensure
            @running_mutex.synchronize { @running = false }
          end
        end

        true
      end

      def handle_agent_event(event)
        @translator.translate(event)
      end

      def resolve_tools(tool_list)
        return default_tools if tool_list.nil?

        tool_list.map do |t|
          case t
          when Class then t.new
          when String then resolve_tool_by_name(t)
          else t
          end
        end
      end

      def resolve_tool_by_name(name)
        case name.downcase
        when "bash" then Ask::Tools::Bash.new
        when "read" then Ask::Tools::Read.new
        when "write" then Ask::Tools::Write.new
        when "edit" then Ask::Tools::Edit.new
        when "glob" then Ask::Tools::Glob.new
        when "grep" then Ask::Tools::Grep.new
        when "code" then Ask::Tools::Code.new
        else raise ArgumentError, "Unknown tool: #{name}"
        end
      end

      def default_tools
        [
          Ask::Tools::Bash.new,
          Ask::Tools::Read.new,
          Ask::Tools::Write.new,
          Ask::Tools::Edit.new,
          Ask::Tools::Glob.new,
          Ask::Tools::Grep.new
        ]
      end
    end

    # Approval queue that emits canonical approval events through the
    # session's EventTranslator whenever actions are submitted or change
    # status, so clients can stream approval state in real time.
    #
    # The session wires its own apply/reject/submit callbacks onto the
    # queue (see Session#build_approval); this subclass only adds
    # observation hooks on top, using its own listeners so the session's
    # on_submit (pending-tool registration) is never clobbered.
    class EmittingApprovalQueue < Ask::Agent::ApprovalQueue
      # @param on_submit [Proc, nil] called with the new {Action} after
      #   submission (and after the auto-approval drain)
      # @param on_status [Proc, nil] called with an {Action} whose status
      #   changed to :approved or :rejected
      def initialize(on_submit: nil, on_status: nil, **kwargs)
        @on_action_submitted = on_submit
        @on_status = on_status
        super(**kwargs)
      end

      def submit(tool_call_id:, tool_name:, args: {}, auto_approvable: false, message: nil)
        id = super
        @on_action_submitted&.call(self[id])
        id
      end

      private

      def apply(action)
        result = super
        @on_status&.call(action.with(status: :approved))
        result
      end

      def reject_action(action)
        result = super
        @on_status&.call(action.with(status: :rejected))
        result
      end
    end
  end
end
