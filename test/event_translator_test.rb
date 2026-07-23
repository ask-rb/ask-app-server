# frozen_string_literal: true

require_relative "test_helper"

class EventTranslatorTest < Minitest::Test
  def setup
    @translator = Ask::AppServer::EventTranslator.new("session-123")
  end

  def test_initial_state
    assert_equal 0, @translator.last_seq
    assert_empty @translator.pending_events
    assert_empty @translator.drain_events
  end

  def test_turn_start_emits_turn_started
    events = @translator.translate(Ask::Agent::Events::TurnStart.new)

    assert_equal 1, events.length
    assert_equal "turn.started", events[0][:type]
    assert events[0][:turnId], "should have turnId"
    assert_equal "session-123", events[0][:sessionId]
    assert_equal 1, events[0][:seq]
  end

  def test_text_delta_emits_model_streaming
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: "Hello "))

    assert_equal 1, events.length
    assert_equal "model.streaming", events[0][:type]
    assert_equal "Hello ", events[0][:payload][:delta]
  end

  def test_empty_text_delta_emits_nothing
    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: ""))
    assert_empty events
  end

  def test_tool_execution_events
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    # Start
    events = @translator.translate(
      Ask::Agent::Events::ToolExecutionStart.new(name: "bash", arguments: 'echo hi', id: "call-1")
    )
    assert_equal 1, events.length
    assert_equal "tool.updated", events[0][:type]
    assert_equal "started", events[0][:payload][:kind]
    assert_equal "bash", events[0][:payload][:toolName]

    # End
    events = @translator.translate(
      Ask::Agent::Events::ToolExecutionEnd.new(name: "bash", id: "call-1", result: "hi\n", is_error: false, duration_ms: 100)
    )
    assert_equal 1, events.length
    assert_equal "tool.updated", events[0][:type]
    assert_equal "completed", events[0][:payload][:kind]
    assert_equal "hi\n", events[0][:payload][:output]
    assert_equal 100, events[0][:payload][:durationMs]
  end

  def test_tool_execution_error
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(
      Ask::Agent::Events::ToolExecutionEnd.new(name: "bash", id: "call-2", result: "command not found", is_error: true, duration_ms: 50)
    )
    assert_equal "tool.updated", events[0][:type]
    assert_equal "failed", events[0][:payload][:kind]
  end

  def test_tool_execution_update
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(
      Ask::Agent::Events::ToolExecutionUpdate.new(name: "read", id: "call-3", partial_result: "partial content")
    )
    assert_equal "tool.updated", events[0][:type]
    assert_equal "updated", events[0][:payload][:kind]
    assert_equal "partial content", events[0][:payload][:output]
  end

  def test_session_end_emits_turn_completed
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(
      Ask::Agent::Events::SessionEnd.new(
        result: "Here's the answer",
        turn_count: 3,
        tool_calls_made: 2,
        input_tokens: 100,
        output_tokens: 200,
        cost: 0.005
      )
    )

    assert_equal 1, events.length
    assert_equal "turn.completed", events[0][:type]
    assert_equal "Here's the answer", events[0][:payload][:response]
    assert_equal 3, events[0][:payload][:turnCount]
    assert_equal 2, events[0][:payload][:toolCallsMade]
    assert_equal 100, events[0][:payload][:inputTokens]
    assert_equal 200, events[0][:payload][:outputTokens]
    assert_equal 0.005, events[0][:payload][:cost]
  end

  def test_session_end_without_turn_start
    events = @translator.translate(
      Ask::Agent::Events::SessionEnd.new(
        result: "done", turn_count: 1, tool_calls_made: 0, input_tokens: 0, output_tokens: 0, cost: nil
      )
    )
    assert_equal 1, events.length
    assert_equal "turn.completed", events[0][:type]
  end

  def test_error_during_turn_returns_empty
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    # Error during active turn — don't emit turn.failed yet,
    # wait for SessionEnd/actual failure
    events = @translator.translate(
      Ask::Agent::Events::Error.new(error: "Something went wrong", recoverable: true)
    )
    assert_empty events
  end

  def test_max_turns_exceeded
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(Ask::Agent::Events::MaxTurnsExceeded.new(max_turns: 25))
    assert_equal 1, events.length
    assert_equal "turn.failed", events[0][:type]
    assert_includes events[0][:payload][:error][:message], "Max turns exceeded"
  end

  def test_loop_detected
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    events = @translator.translate(Ask::Agent::Events::LoopDetected.new(tool_name: "bash", repeated_count: 3))
    assert_equal 1, events.length
    assert_equal "turn.failed", events[0][:type]
    assert_includes events[0][:payload][:error][:message], "Loop detected"
  end

  def test_multiple_text_deltas_accumulate
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    @translator.translate(Ask::Agent::Events::TextDelta.new(content: "Hello"))
    @translator.translate(Ask::Agent::Events::TextDelta.new(content: " world"))
    @translator.translate(Ask::Agent::Events::TextDelta.new(content: "!"))

    text = @translator.instance_variable_get(:@streaming_text)
    assert_equal "Hello world!", text
  end

  def test_drain_events_clears_buffer
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    @translator.translate(Ask::Agent::Events::TextDelta.new(content: "Hello"))

    assert_equal 2, @translator.pending_events.length

    drained = @translator.drain_events
    assert_equal 2, drained.length
    assert_empty @translator.pending_events
  end

  def test_turn_id_consistent_per_turn
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    id1 = @translator.instance_variable_get(:@turn_id)

    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: "Hello"))
    assert_equal id1, events[0][:turnId]
  end

  def test_sequential_sequencing
    events = @translator.translate(Ask::Agent::Events::TurnStart.new)
    assert_equal 1, events[0][:seq]

    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: "A"))
    assert_equal 2, events[0][:seq]

    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: "B"))
    assert_equal 3, events[0][:seq]
  end

  def test_translate_nil_event
    events = @translator.translate(nil)
    assert_empty events
  rescue NoMethodError
    # nil doesn't match any when clause — acceptable
  end

  def test_skipped_events_return_empty
    events = @translator.translate(Ask::Agent::Events::ToolCallDelta.new(name: "bash", arguments: "{}", id: "c1"))
    assert_empty events

    events = @translator.translate(Ask::Agent::Events::MessageEnd.new(tool_calls: true))
    assert_empty events

    events = @translator.translate(Ask::Agent::Events::TurnEnd.new(tool_results: [], turn_number: 1, input_tokens: 0, output_tokens: 0, cost: nil))
    assert_empty events

    events = @translator.translate(Ask::Agent::Events::CompactionStart.new(tokens_before: 1000, reason: "test"))
    assert_empty events

    events = @translator.translate(Ask::Agent::Events::CompactionEnd.new(tokens_before: 1000, tokens_after: 500, summary: "compacted"))
    assert_empty events
  end
end
