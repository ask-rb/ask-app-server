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
    #
    # The durable ask-session layer: every session has an
    # Ask::Session::Host record, and each canonical event is appended to
    # it at this boundary (protocol translation stays here — the Host is
    # an event-sourced log, it knows nothing about the wire vocabulary).
    # Replay and cursor delivery read the Host, so the durable log is the
    # source of truth; the translator's in-memory buffer serves live
    # observers only. A successful run also appends an agent.snapshot
    # (the ask-agent restart-resume payload); restart resume rebuilds a
    # fresh session through Ask::Agent::SessionAdapter.resume when the
    # Host holds one ({#resume_from_host}).
    class AgentAdapter
      # Event types the ask-session Host writes itself (Host#create /
      # Host#close). The adapter must not re-append them: the read path
      # maps the Host's lifecycle payloads back to the wire shape, which
      # keeps Host seq and wire seq contiguous from 1.
      HOST_OWNED_EVENT_TYPES = %w[session.created session.ended].freeze

      # Approval scopes this host honors. The queue itself knows
      # :once/:session/:project, but the app-server only offers
      # once/session — :project is rejected explicitly, never silently
      # downgraded.
      ALLOWED_APPROVAL_SCOPES = %i[once session].freeze

      # The underlying ask-agent session.
      attr_reader :session

      # The event translator that accumulates protocol events.
      attr_reader :translator

      # The session ID (same as ask-agent session id).
      attr_reader :session_id

      # The durable ask-session host this session's records live in.
      attr_reader :host

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
      # @param host [Ask::Session::Host, nil] durable session/event host;
      #   defaults to a private in-process Host
      # @param state_adapter [Object, nil] ask-state-providers adapter
      #   (get/set/delete) used to construct a ProviderStore-backed Host
      #   when no +host+ is given; ignored when +host+ is provided
      # @param created_at [Time, nil] session creation time (restart
      #   resume passes the durable record's timestamp)
      # @param session_opts [Hash] remaining options passed to
      #   Ask::Agent::Session.new (hooks, plan_mode, todos, ...)
      def initialize(model:, tools: nil, system_prompt: nil, agent_dir: nil,
                     approval: :off, require_approval: nil, host: nil,
                     state_adapter: nil, created_at: nil, **session_opts)
        @model = model
        @system_prompt = system_prompt
        @tools = resolve_tools(tools)
        @session_opts = session_opts
        @approval = approval
        @require_approval = require_approval
        @agent_dir = agent_dir
        @host = host || build_durable_host(state_adapter)
        @durable_record = false
        # The session's workspace is the tools' home: bash commands
        # without an explicit cd run there (default_workdir), so the
        # agent never drifts into the host's cwd — the recurring
        # "where is the project?" failure mode.
        @tools.each { |tool| tool.default_workdir = @agent_dir if tool.respond_to?(:default_workdir=) }
        @session = nil
        @translator = nil
        @on_event_block = nil
        @session_id = nil
        @running = false
        @running_mutex = Mutex.new
        @run_thread = nil
        @abort_requested = false
        @created_at = created_at || Time.now
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Start a new ask-agent session.
      # Returns the session ID.
      def start_session
        @translator = EventTranslator.new
        @translator.on_event = @on_event_block if @on_event_block
        @session = build_session
        @session_id = @session.id
        create_durable_record
        @translator.on_append = method(:persist_event)
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
        # Attach to the durable record when the Host already knows this
        # session (full history stays replayable); otherwise this adapter
        # runs translator-buffer-only, as before.
        @durable_record = durable_record?
        @translator.on_append = method(:persist_event) if @durable_record
        @session.on_event { |event| handle_agent_event(event) }
        @session_id
      end

      # Rebuild this adapter around a durable session the Host already
      # records (restart resume): a fresh compatible ask-agent session
      # under the same id, restored from the latest agent.snapshot when
      # one exists, then attached through the regular {#resume} path.
      #
      # Model/tools/prompt configuration is intentionally not
      # deserialized — the caller configures this adapter with its own
      # defaults before calling.
      def resume_from_host(session_id)
        @session = build_session(id: session_id)
        @session_id = session_id
        restore_from_snapshot
        resume(@session)
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
          payload["allowedScopes"] = %w[once session]
          Ask::SessionProtocol::Interactions.interaction(
            id: "act_#{action.id}", kind: "approval", status: "pending", payload: payload
          )
        end
      end

      # Approve a pending approval interaction by canonical id ("act_N").
      # @param scope [Symbol, String] :once (default) or :session.
      #   :project is rejected explicitly via InvalidRequest.
      # @return [Boolean] whether an action was approved
      def approve_interaction(interaction_id, scope: :once)
        normalized = normalize_approval_scope!(scope)
        apply_interaction(interaction_id) { |queue, id| queue.approve(id, scope: normalized) }
      end

      # Reject a pending approval interaction by canonical id ("act_N").
      # @param feedback [String, nil] client-supplied denial reason,
      #   retained on the action and surfaced in approval.updated.
      # @return [Boolean] whether an action was rejected
      def reject_interaction(interaction_id, feedback: nil)
        apply_interaction(interaction_id) { |queue, id| queue.reject(id, feedback: feedback) }
      end

      # Approve every pending approval interaction.
      # @param scope [Symbol, String] :once (default) or :session
      # @return [Integer] number approved
      def approve_all_interactions(scope: :once)
        normalized = normalize_approval_scope!(scope)
        queue = @session&.approval_queue
        return 0 unless queue

        queue.approve_all(scope: normalized).size
      end

      # Reject every pending approval interaction.
      # @param feedback [String, nil] denial reason applied to each
      # @return [Integer] number rejected
      def reject_all_interactions(feedback: nil)
        queue = @session&.approval_queue
        return 0 unless queue

        queue.reject_all(feedback: feedback).size
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

      # Close the session: delete its state, emit session.ended, and
      # close the durable ask-session record.
      def close!
        @session&.delete if @session.respond_to?(:delete)
        @translator&.session_ended(@session_id, reason: "closed")
        close_durable_record
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
      #
      # The durable ask-session log is the source of truth: replay and
      # cursor delivery read Host#events and re-validate each record as a
      # canonical protocol event at this boundary. Falls back to the
      # in-memory translator buffer only when this adapter has no durable
      # record (resume() attached to a session the Host does not know).
      def events_after(after_seq)
        after = after_seq.to_i
        return pending_events.select { |e| e.seq > after } unless @durable_record

        @host.events(@session_id, after_seq: after).filter_map { |record| wire_event(record) }
      rescue Ask::Session::NotFoundError
        pending_events.select { |e| e.seq > after }
      end

      private

      # Build the durable Host from an injectable state adapter (any
      # ask-state-providers get/set/delete backend, wrapped in
      # ProviderStore). No adapter means the default in-process Host —
      # durability is opt-in and no concrete backend is forced.
      def build_durable_host(state_adapter)
        return Ask::Session::Host.new unless state_adapter

        Ask::Session::Host.new(store: Ask::Session::ProviderStore.new(adapter: state_adapter))
      end

      # Restore the conversation from the durable snapshot through
      # Ask::Agent::SessionAdapter.resume. That adapter registers its
      # own durable event handler as it attaches, which would append
      # ask-agent-shaped events alongside this adapter's protocol events
      # (double-writing the log with a second, non-wire vocabulary) —
      # restoration is done at that point, so the handler it just added
      # is popped off and the EventTranslator stays the single protocol
      # writer.
      def restore_from_snapshot
        return false unless durable_snapshot?

        Ask::Agent::SessionAdapter.resume(agent: @session, host: @host, session_id: @session_id)
        handlers = @session.instance_variable_get(:@event_handlers)
        handlers[:all].pop if handlers
        true
      rescue Ask::Agent::SessionAdapter::Error => e
        @logger.debug("Snapshot restore skipped for #{@session_id}: #{e.message}")
        false
      end

      # Whether the durable Host holds a restart-resume snapshot for
      # this session.
      def durable_snapshot?
        return false unless @host && @session_id

        @host.events(@session_id).any? { |e| e.type == Ask::Agent::SessionAdapter::SNAPSHOT_TYPE }
      rescue Ask::Session::NotFoundError
        false
      end

      # Create the durable ask-session record. The Host's own
      # session.created event is the session's first durable event; the
      # translator's session.created (identical wire shape, seq 1) is
      # served from it via #wire_event instead of being re-appended.
      def create_durable_record
        @host.create(id: @session_id, metadata: { model: @model })
        @durable_record = true
      end

      # Whether the Host already holds a record for this session.
      def durable_record?
        return false unless @host && @session_id

        @host.session(@session_id)
        true
      rescue Ask::Session::NotFoundError
        false
      end

      # Append a canonical protocol event to the durable Host. The Host is
      # a dumb log: protocol vocabulary enters and leaves at this
      # boundary. Host-owned lifecycle events are skipped (see
      # HOST_OWNED_EVENT_TYPES). Failures never break live delivery — a
      # close racing a run just stops receiving durable appends.
      def persist_event(event)
        return unless @durable_record
        return if HOST_OWNED_EVENT_TYPES.include?(event.type)

        @host.append(@session_id, type: event.type, payload: event.payload)
      rescue StandardError => e
        @logger.debug("Durable append failed for #{event.type}: #{e.message}")
      end

      # Close the durable record (Host writes session.ended itself).
      # Already-closed/aborted records are fine to ignore.
      def close_durable_record
        return unless @durable_record

        @host.close(@session_id, reason: "closed")
      rescue Ask::Session::Error
        nil
      end

      # Append the end-of-run snapshot the restart-resume path restores
      # through Ask::Agent::SessionAdapter.resume (same payload shape:
      # messages + turn_count). Written only after a clean run — an
      # aborted or failed turn leaves no half-restorable state. The Host
      # keeps it; wire_event filters it out of protocol replay (it is
      # not a protocol vocabulary type). Failures never break the live
      # turn.
      def persist_snapshot
        return unless @durable_record
        return unless @session.respond_to?(:chat) && @session.respond_to?(:turn_count)

        @host.append(
          @session_id,
          type: Ask::Agent::SessionAdapter::SNAPSHOT_TYPE,
          payload: {
            messages: @session.chat.messages.map(&:to_h),
            turn_count: @session.turn_count || 0
          }
        )
      rescue StandardError => e
        @logger.debug("Durable snapshot failed for #{@session_id}: #{e.message}")
      end

      # Rebuild a durable Host record as a canonical wire event.
      # Returns nil for records outside the protocol vocabulary (e.g.
      # ask-session-internal types), which never reach clients.
      def wire_event(record)
        return nil unless Ask::SessionProtocol::Events.known?(record.type)

        payload =
          case record.type
          when "session.created"
            { "sessionId" => record.session_id }
          when "session.ended"
            reason = record.payload[:reason] || record.payload["reason"] || "closed"
            { "sessionId" => record.session_id, "reason" => reason.to_s }
          else
            # Host Event rehydration (and the durable ProviderStore JSON
            # round-trip) symbolizes payload keys; the wire contract is
            # string-keyed. Normalize here, at the protocol boundary.
            record.payload.transform_keys(&:to_s)
          end
        Ask::SessionProtocol::Events.event(type: record.type, seq: record.seq, payload: payload)
      rescue ArgumentError => e
        @logger.debug("Skipping non-wire durable event #{record.type}: #{e.message}")
        nil
      end

      def build_session(id: nil)
        opts = @session_opts.dup
        hooks = opts.delete(:hooks) || {}
        approval_option = build_approval_option
        opts[:approval] = approval_option if approval_option
        opts[:plan_mode] = false unless opts.key?(:plan_mode)
        opts[:id] = id if id

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

      # Normalize and validate an approval scope. Omitted scope defaults
      # to :once (backward compatible). Anything outside
      # ALLOWED_APPROVAL_SCOPES — notably :project — raises InvalidRequest
      # explicitly instead of silently downgrading.
      def normalize_approval_scope!(scope)
        normalized = if scope.nil?
          :once
        elsif scope.is_a?(String) || scope.is_a?(Symbol)
          scope.to_sym
        end
        unless ALLOWED_APPROVAL_SCOPES.include?(normalized)
          raise InvalidRequest,
                "Unsupported approval scope '#{scope}' (supported: #{ALLOWED_APPROVAL_SCOPES.join(', ')})"
        end
        normalized
      end

      def start_run(content)
        @running_mutex.synchronize do
          @abort_requested = false
          @running = true
        end

        @run_thread = Thread.new do
          failure = nil
          begin
            @session.run(content, reset: false)
            # Drain steers queued while the turn was running (mid-execution
            # injection): each subsequent run processes one queued message.
            while @session.queued_steers.positive?
              @session.run("", reset: false)
            end
            # A run that returned with the turn still active ended
            # without a terminal event — the model stream dropped
            # mid-turn (a dead connection, a provider that closed the
            # stream early). Without this, the client would wait on a
            # ghost run forever. Surface it as a failure so the fix
            # loop can redeliver. No snapshot in that case: the turn's
            # conversation state is incomplete.
            if @translator.turn_active?
              @logger.error("Turn ended without a completion event — the model stream dropped mid-turn")
              failure = "The model stream ended without completing the turn (the connection dropped mid-stream)"
            else
              persist_snapshot
            end
          rescue => e
            # An aborted turn raises Ask::Agent::Aborted — that's not a
            # failure, the client asked for it. Everything else is a
            # run failure the client must see — a raised run, or a
            # disconnect from the model (EOF, ECONNRESET, a closed
            # socket) surfaced as an exception: without a turn.failed,
            # a watching board would wait forever on a dead turn. The
            # translator's failure event carries the message.
            unless e.is_a?(Ask::Agent::Aborted) || e.class.name.to_s.include?("Aborted")
              @logger.error("Agent run failed: #{e.class}: #{e.message}")
              message = e.message.to_s
              message = e.class.name if message.strip.empty?
              failure = message[0, 500]
            end
          ensure
            # Settle the run before the terminal event goes out: a
            # watcher woken by turn.failed (an observer, the pane
            # reporter) must see the run as finished, not a ghost
            # "working" it will never see corrected — no state event
            # fires after this point.
            @running_mutex.synchronize { @running = false }
            emit_failure(failure) if failure
            @logger.debug("Run thread ended: turn_active=#{@translator.turn_active?} last_seq=#{@translator.last_seq}")
          end
        end

        true
      end

      # Wake the watchers: translate the run's terminal failure into a
      # turn.failed event. Never raises — if emission itself failed, a
      # raised error here would kill the run thread after the fact and
      # leave the turn marked active with no terminal event, hanging
      # every watcher this method exists to wake.
      def emit_failure(message)
        @translator.turn_failed(message)
      rescue StandardError => e
        @logger.error("Failed to emit turn.failed: #{e.class}: #{e.message}")
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
        else
          # Deployment-registered tools (e.g. the board's executor tools
          # via ASK_APP_SERVER_PRELOAD) resolve from the global registry
          # (which returns instances, matched by tool name).
          tool = Ask::Tools[name]
          raise ArgumentError, "Unknown tool: #{name}" unless tool

          tool
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
    class EmittingApprovalQueue < Ask::Permissions::ApprovalQueue
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

      def apply(action, scope: :once)
        result = super(action, scope: scope)
        @on_status&.call(result)
        result
      end

      def reject_action(action, feedback: nil)
        result = super(action, feedback: feedback)
        @on_status&.call(result)
        result
      end
    end
  end
end
