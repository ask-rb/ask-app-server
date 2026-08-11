# frozen_string_literal: true

require "securerandom"

module Ask
  module AppServer
    # Translates ask-agent runtime events into canonical
    # Ask::SessionProtocol events (the contract between the host and every
    # client). Every emitted event is validated against the protocol
    # registry, so a malformed translation fails fast at the boundary.
    #
    # The translator owns the per-session event buffer and sequence
    # numbers: clients poll (`session/events` after seq N) or subscribe
    # (the server pushes drained events as `session/event` notifications).
    class EventTranslator
      # Events retained per session for replay/polling. Cursor-based
      # delivery means the log is append-only; clients with cursors older
      # than the cap miss the dropped events (durable log is a host
      # storage concern).
      MAX_EVENTS = 2000

      def initialize
        @events = []
        @seq = 0
        @turn_id = nil
        @turn_active = false
        @streaming_text = +""
        @plan_interaction_id = nil
      end

      # Translate one ask-agent event into zero or more canonical events.
      # Returns an array of Ask::SessionProtocol::Events::Event (may be
      # empty); events are buffered for delivery.
      def translate(agent_event)
        case agent_event
        when Ask::Agent::Events::TurnStart
          turn_started
        when Ask::Agent::Events::TextDelta
          text_delta(agent_event)
        when Ask::Agent::Events::ThinkingDelta
          thinking_delta(agent_event)
        when Ask::Agent::Events::ToolCallDelta
          # Informational; execution events carry the tool lifecycle.
          []
        when Ask::Agent::Events::ToolExecutionStart
          tool_start(agent_event)
        when Ask::Agent::Events::ToolExecutionUpdate
          tool_update(agent_event)
        when Ask::Agent::Events::ToolExecutionEnd
          tool_end(agent_event)
        when Ask::Agent::Events::TodoUpdated
          todos_updated(agent_event)
        when Ask::Agent::Events::PlanProposed
          plan_proposed(agent_event)
        when Ask::Agent::Events::PlanApproved
          plan_approved(agent_event)
        when Ask::Agent::Events::PlanRejected
          plan_rejected(agent_event)
        when Ask::Agent::Events::MaxTurnsExceeded
          turn_failed("Max turns exceeded (#{agent_event.max_turns})")
        when Ask::Agent::Events::LoopDetected
          turn_failed("Loop detected on tool: #{agent_event.tool_name}")
        when Ask::Agent::Events::Error
          error(agent_event)
        when Ask::Agent::Events::SessionEnd
          session_end(agent_event)
        else
          # TurnEnd, MessageStart/End, Reflection*, Compaction*,
          # SessionRolledBack/Forked, Evaluation*, MetaAgentAnalysis —
          # internal detail, no canonical representation.
          []
        end
      end

      # ── Queue/plan-driven emission (not ask-agent events) ──────────────

      # An approval action was queued: emit approval.required.
      #
      # @param action [Ask::Agent::ApprovalQueue::Action]
      def approval_required(action)
        payload = { "toolName" => action.tool_name.to_s }
        payload["args"] = action.args if action.args
        payload["message"] = action.message if action.message
        payload["autoApprovable"] = action.auto_approvable unless action.auto_approvable.nil?
        emit("approval.required", payload.merge("id" => "act_#{action.id}"))
      end

      # An approval action changed status: emit approval.updated.
      #
      # @param action [Ask::Agent::ApprovalQueue::Action]
      def approval_updated(action)
        status = action.status.to_s
        return unless %w[approved rejected].include?(status)

        emit("approval.updated", { "id" => "act_#{action.id}", "status" => status })
      end

      # A session was created: emit session.created.
      def session_created(session_id)
        emit("session.created", { "sessionId" => session_id })
      end

      # A session ended: emit session.ended.
      def session_ended(session_id, reason: "closed")
        emit("session.ended", { "sessionId" => session_id, "reason" => reason })
      end

      # ── Buffer access ──────────────────────────────────────────────────

      # All events since the last drain.
      def pending_events
        @events
      end

      # Drain and return all pending events, clearing the buffer.
      def drain_events
        evs = @events
        @events = []
        evs
      end

      # The last sequence number we emitted.
      def last_seq
        @seq
      end

      # Events after a given sequence number.
      def events_after(after_seq)
        @events.select { |e| e.seq > after_seq }
      end

      private

      def next_seq
        @seq += 1
      end

      def turn_started
        @turn_id = SecureRandom.uuid
        @turn_active = true
        @streaming_text = +""
        emit("turn.started", { "turnId" => @turn_id })
      end

      def text_delta(event)
        content = event.content.to_s
        return [] if content.empty?

        @streaming_text << content
        emit("model.streaming", { "delta" => content })
      end

      def thinking_delta(event)
        content = event.content.to_s
        return [] if content.empty?

        emit("model.thinking", { "delta" => content })
      end

      def tool_start(event)
        payload = {
          "id" => event.id.to_s,
          "name" => event.name.to_s,
          "args" => event.arguments
        }
        emit("tool.use", payload)
      end

      def tool_update(event)
        payload = {
          "id" => event.id.to_s,
          "name" => event.name.to_s,
          "partial" => event.partial_result.to_s
        }
        emit("tool.delta", payload)
      end

      def tool_end(event)
        payload = {
          "id" => event.id.to_s,
          "name" => event.name.to_s,
          "output" => event.result,
          "isError" => !!event.is_error,
          "durationMs" => event.duration_ms
        }
        emit("tool.result", payload)
      end

      def todos_updated(event)
        todos = event.todos.map { |entry| entry.to_h.transform_keys(&:to_s) }
        emit("todos.updated", { "todos" => todos })
      end

      def plan_proposed(event)
        @plan_interaction_id = "plan_#{next_seq}"
        emit("plan.proposed", { "id" => @plan_interaction_id, "plan" => event.plan.to_s })
      end

      def plan_approved(event)
        payload = { "plan" => event.plan.to_s }
        payload["id"] = @plan_interaction_id if @plan_interaction_id
        emit("plan.approved", payload)
      end

      def plan_rejected(event)
        payload = { "plan" => event.plan.to_s }
        payload["id"] = @plan_interaction_id if @plan_interaction_id
        emit("plan.rejected", payload)
      end

      def session_end(event)
        @turn_active = false
        payload = {}
        payload["turnId"] = @turn_id if @turn_id
        payload["response"] = event.result.to_s
        payload["inputTokens"] = event.input_tokens if event.input_tokens
        payload["outputTokens"] = event.output_tokens if event.output_tokens
        payload["cost"] = event.cost if event.cost
        emit("turn.completed", payload)
      end

      def error(event)
        payload = { "error" => event.error.to_s }
        payload["recoverable"] = event.recoverable unless event.recoverable.nil?
        emit("error", payload)
      end

      def turn_failed(message)
        @turn_active = false
        payload = { "error" => message.to_s }
        payload["turnId"] = @turn_id if @turn_id
        emit("turn.failed", payload)
      end

      def emit(type, payload)
        event = Ask::SessionProtocol::Events.event(type: type, seq: next_seq, payload: payload)
        @events << event
        @events.shift if @events.size > MAX_EVENTS
        [event]
      end
    end
  end
end
