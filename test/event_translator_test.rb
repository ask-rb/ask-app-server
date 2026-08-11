# frozen_string_literal: true

require_relative "test_helper"

class EventTranslatorTest < Minitest::Test
  def setup
    @translator = Ask::AppServer::EventTranslator.new
  end

  # ── Initial state ──────────────────────────────────────────────────────

  def test_initial_state
    assert_equal 0, @translator.last_seq
    assert_empty @translator.pending_events
    assert_empty @translator.drain_events
  end

  def test_events_are_canonical_and_validated
    events = @translator.translate(Ask::Agent::Events::TurnStart.new)

    assert_equal 1, events.length
    event = events[0]
    assert_instance_of Ask::SessionProtocol::Events::Event, event
    assert_equal "turn.started", event.type
    assert_equal 1, event.seq
    assert event.payload["turnId"], "turn.started should carry a turnId"
    assert_equal event, @translator.pending_events[0]
  end

  def test_malformed_emission_fails_fast
    # Force an invalid payload through the private emit path: the protocol
    # registry must reject it.
    assert_raises(ArgumentError) do
      @translator.send(:emit, "model.streaming", { "wrong" => "field" })
    end
  end

  # ── Turn lifecycle ─────────────────────────────────────────────────────

  def test_turn_start_emits_turn_started
    events = @translator.translate(Ask::Agent::Events::TurnStart.new)
    assert_equal "turn.started", events[0].type
  end

  def test_text_delta_emits_model_streaming
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: "Hello "))

    assert_equal 1, events.length
    assert_equal "model.streaming", events[0].type
    assert_equal "Hello ", events[0].payload["delta"]
  end

  def test_empty_text_delta_emits_nothing
    events = @translator.translate(Ask::Agent::Events::TextDelta.new(content: ""))
    assert_empty events
  end

  def test_thinking_delta_emits_model_thinking
    events = @translator.translate(Ask::Agent::Events::ThinkingDelta.new(content: "hmm"))
    assert_equal "model.thinking", events[0].type
    assert_equal "hmm", events[0].payload["delta"]
  end

  def test_session_end_emits_turn_completed
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    events = @translator.translate(
      Ask::Agent::Events::SessionEnd.new(
        result: "done", turn_count: 1, tool_calls_made: 2,
        input_tokens: 10, output_tokens: 20, cost: 0.001
      )
    )

    assert_equal 1, events.length
    event = events[0]
    assert_equal "turn.completed", event.type
    assert_equal "done", event.payload["response"]
    assert_equal 10, event.payload["inputTokens"]
    assert_equal 20, event.payload["outputTokens"]
    assert_equal 0.001, event.payload["cost"]
    assert event.payload["turnId"]
  end

  def test_max_turns_exceeded_emits_turn_failed
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    events = @translator.translate(Ask::Agent::Events::MaxTurnsExceeded.new(max_turns: 25))

    assert_equal "turn.failed", events[0].type
    assert_match(/Max turns exceeded/, events[0].payload["error"])
  end

  def test_loop_detected_emits_turn_failed
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    events = @translator.translate(Ask::Agent::Events::LoopDetected.new(tool_name: "bash", repeated_count: 3))

    assert_equal "turn.failed", events[0].type
    assert_match(/Loop detected on tool: bash/, events[0].payload["error"])
  end

  def test_error_emits_error_event
    events = @translator.translate(Ask::Agent::Events::Error.new(error: "boom", recoverable: true))
    assert_equal "error", events[0].type
    assert_equal "boom", events[0].payload["error"]
    assert_equal true, events[0].payload["recoverable"]
  end

  def test_internal_events_emit_nothing
    assert_empty @translator.translate(Ask::Agent::Events::TurnEnd.new(tool_results: [], turn_number: 1, input_tokens: 1, output_tokens: 1, cost: 0.0))
    assert_empty @translator.translate(Ask::Agent::Events::ReflectionStart.new(reflection_number: 1))
    assert_empty @translator.translate(Ask::Agent::Events::CompactionStart.new(tokens_before: 1, reason: "full"))
    assert_empty @translator.translate(Ask::Agent::Events::MessageEnd.new(tool_calls: false))
    assert_empty @translator.translate(Ask::Agent::Events::ToolCallDelta.new(name: "bash", arguments: "{}", id: "c1"))
  end

  # ── Tools ──────────────────────────────────────────────────────────────

  def test_tool_lifecycle_events
    @translator.translate(Ask::Agent::Events::TurnStart.new)

    start = @translator.translate(
      Ask::Agent::Events::ToolExecutionStart.new(name: "bash", arguments: { "command" => "echo hi" }, id: "call-1")
    )
    assert_equal "tool.use", start[0].type
    assert_equal "call-1", start[0].payload["id"]
    assert_equal "bash", start[0].payload["name"]
    assert_equal({ "command" => "echo hi" }, start[0].payload["args"])

    update = @translator.translate(
      Ask::Agent::Events::ToolExecutionUpdate.new(name: "bash", id: "call-1", partial_result: "hi")
    )
    assert_equal "tool.delta", update[0].type
    assert_equal "hi", update[0].payload["partial"]

    finish = @translator.translate(
      Ask::Agent::Events::ToolExecutionEnd.new(name: "bash", id: "call-1", result: "hi\n", is_error: false, duration_ms: 100)
    )
    assert_equal "tool.result", finish[0].type
    assert_equal "hi\n", finish[0].payload["output"]
    assert_equal false, finish[0].payload["isError"]
    assert_equal 100, finish[0].payload["durationMs"]
  end

  # ── Todos and plan ─────────────────────────────────────────────────────

  def test_todos_updated
    entry = Ask::Agent::TodoList::Entry.new(id: "todo_1", title: "Fix bug", status: "in_progress")
    events = @translator.translate(Ask::Agent::Events::TodoUpdated.new(todos: [entry]))

    assert_equal "todos.updated", events[0].type
    assert_equal [{ "id" => "todo_1", "title" => "Fix bug", "status" => "in_progress" }], events[0].payload["todos"]
  end

  def test_plan_proposed_and_resolved
    proposed = @translator.translate(Ask::Agent::Events::PlanProposed.new(plan: "Step 1"))
    assert_equal "plan.proposed", proposed[0].type
    assert_equal "Step 1", proposed[0].payload["plan"]
    assert_match(/\Aplan_\d+\z/, proposed[0].payload["id"])

    approved = @translator.translate(Ask::Agent::Events::PlanApproved.new(plan: "Step 1"))
    assert_equal "plan.approved", approved[0].type
    assert_equal proposed[0].payload["id"], approved[0].payload["id"]

    rejected = @translator.translate(Ask::Agent::Events::PlanRejected.new(plan: "Step 1"))
    assert_equal "plan.rejected", rejected[0].type
    assert_equal proposed[0].payload["id"], rejected[0].payload["id"]
  end

  # ── Approvals (queue-driven) ───────────────────────────────────────────

  def test_approval_required_and_updated
    queue = Ask::Agent::ApprovalQueue.new
    id = queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" }, message: "dangerous")

    @translator.approval_required(queue[id])
    event = @translator.pending_events.last
    assert_equal "approval.required", event.type
    assert_equal "act_1", event.payload["id"]
    assert_equal "bash", event.payload["toolName"]
    assert_equal({ "command" => "ls" }, event.payload["args"])
    assert_equal "dangerous", event.payload["message"]

    @translator.approval_updated(queue[id].with(status: :approved))
    event = @translator.pending_events.last
    assert_equal "approval.updated", event.type
    assert_equal "act_1", event.payload["id"]
    assert_equal "approved", event.payload["status"]
  end

  def test_approval_updated_ignores_unknown_statuses
    queue = Ask::Agent::ApprovalQueue.new
    id = queue.submit(tool_call_id: "call-1", tool_name: "bash")

    @translator.approval_updated(queue[id].with(status: :applying))
    assert_empty @translator.pending_events
  end

  # ── Session lifecycle ──────────────────────────────────────────────────

  def test_session_created_and_ended
    @translator.session_created("sess_1")
    created = @translator.pending_events.last
    assert_equal "session.created", created.type
    assert_equal "sess_1", created.payload["sessionId"]

    @translator.session_ended("sess_1", reason: "closed")
    ended = @translator.pending_events.last
    assert_equal "session.ended", ended.type
    assert_equal "sess_1", ended.payload["sessionId"]
    assert_equal "closed", ended.payload["reason"]
  end

  # ── Buffer semantics ───────────────────────────────────────────────────

  def test_seq_increments_and_buffer_drains
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    @translator.translate(Ask::Agent::Events::TextDelta.new(content: "a"))

    assert_equal 2, @translator.last_seq
    assert_equal 2, @translator.pending_events.length

    drained = @translator.drain_events
    assert_equal 2, drained.length
    assert_empty @translator.pending_events
  end

  def test_events_after_filters_by_seq
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    @translator.translate(Ask::Agent::Events::TextDelta.new(content: "a"))

    events = @translator.events_after(1)
    assert_equal 1, events.length
    assert_equal 2, events[0].seq
  end

  def test_events_serialize_to_wire_shape
    @translator.translate(Ask::Agent::Events::TurnStart.new)
    wire = JSON.generate(@translator.pending_events.map(&:to_h))

    assert_equal "turn.started", JSON.parse(wire)[0]["type"]
  end
end
