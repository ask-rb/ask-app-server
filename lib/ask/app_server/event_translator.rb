# frozen_string_literal: true

require "securerandom"

module Ask
  module AppServer
    # Translates ask-agent Events into app-server protocol events.
    #
    # ask-agent emits events like TurnStart, TextDelta, ToolExecutionStart, etc.
    # The app-server protocol uses a different set: turn.started, model.streaming,
    # tool.updated, turn.completed, turn.failed, message.upserted.
    #
    # This class maps between the two models, emitting app-server protocol events
    # that clients such as the Python Telegram bot and Vercel AI SDK expect.
    class EventTranslator
      attr_reader :session_id, :turn_id

      def initialize(session_id)
        @session_id = session_id
        @turn_id = nil
        @seq = 0
        @events = []
        @streaming_text = +""
        @turn_active = false
        @in_reflection = false
      end

      # Translate an ask-agent event into zero or more app-server events.
      # Returns an array of event hashes (may be empty).
      def translate(agent_event)
        case agent_event
        when Ask::Agent::Events::TurnStart
          translate_turn_start
        when Ask::Agent::Events::TextDelta
          translate_text_delta(agent_event)
        when Ask::Agent::Events::ToolCallDelta
          # ToolCallDelta is informational; we track calls but don't emit
          # until execution actually starts.
          []
        when Ask::Agent::Events::ToolExecutionStart
          translate_tool_start(agent_event)
        when Ask::Agent::Events::ToolExecutionUpdate
          translate_tool_update(agent_event)
        when Ask::Agent::Events::ToolExecutionEnd
          translate_tool_end(agent_event)
        when Ask::Agent::Events::MessageEnd
          # Fires after the LLM response is complete (before tool execution).
          # Not mapped directly; we already streamed the text.
          []
        when Ask::Agent::Events::TurnEnd
          # Fires after tool execution completes for one recursive iteration.
          # The session may continue with more tool calls.
          []
        when Ask::Agent::Events::ReflectionStart
          # Reflection is an internal detail — skip
          @in_reflection = true
          []
        when Ask::Agent::Events::ReflectionDelta
          # Treat reflection text as regular model output
          translate_text_delta(agent_event)
        when Ask::Agent::Events::ReflectionEnd
          @in_reflection = false
          []
        when Ask::Agent::Events::CompactionStart
          []
        when Ask::Agent::Events::CompactionEnd
          []
        when Ask::Agent::Events::Error
          translate_error(agent_event)
        when Ask::Agent::Events::SessionEnd
          translate_session_end(agent_event)
        when Ask::Agent::Events::MaxTurnsExceeded
          translate_turn_failed("Max turns exceeded (#{agent_event.max_turns})")
        when Ask::Agent::Events::LoopDetected
          translate_turn_failed("Loop detected on tool: #{agent_event.tool_name}")
        else
          []
        end
      end

      # All events emitted since last poll.
      def pending_events
        @events
      end

      # Drain and return all pending events, clearing the buffer.
      def drain_events
        evs = @events.dup
        @events.clear
        evs
      end

      # The last sequence number we emitted.
      def last_seq
        @seq
      end

      private

      def next_seq
        @seq += 1
        @seq
      end

      def translate_turn_start
        @turn_id = SecureRandom.uuid
        @turn_active = true
        @streaming_text = +""

        ev = build_event("turn.started", { turnId: @turn_id })
        [ev]
      end

      def translate_text_delta(event)
        content = event.content.to_s
        return [] if content.empty?

        @streaming_text << content

        ev = build_event("model.streaming", { delta: content })
        [ev]
      end

      def translate_tool_start(event)
        ev = build_event("tool.updated", {
          toolName: event.name,
          kind: "started",
          input: event.arguments
        })
        [ev]
      end

      def translate_tool_update(event)
        ev = build_event("tool.updated", {
          toolName: event.name,
          kind: "updated",
          output: event.partial_result.to_s
        })
        [ev]
      end

      def translate_tool_end(event)
        kind = event.is_error ? "failed" : "completed"
        ev = build_event("tool.updated", {
          toolName: event.name,
          kind: kind,
          output: event.result.to_s,
          durationMs: event.duration_ms
        })
        [ev]
      end

      def translate_session_end(event)
        @turn_active = false
        response_text = event.result.to_s

        ev = build_event("turn.completed", {
          response: response_text,
          turnCount: event.turn_count,
          toolCallsMade: event.tool_calls_made,
          inputTokens: event.input_tokens,
          outputTokens: event.output_tokens,
          cost: event.cost
        })
        [ev]
      end

      def translate_error(event)
        return [] if @turn_active
        translate_turn_failed(event.error)
      end

      def translate_turn_failed(message)
        @turn_active = false
        ev = build_event("turn.failed", {
          error: { message: message.to_s }
        })
        [ev]
      end

      def build_event(type, payload)
        event = {
          type: type,
          seq: next_seq,
          payload: payload,
          turnId: @turn_id,
          sessionId: @session_id
        }
        @events << event
        event
      end
    end
  end
end
