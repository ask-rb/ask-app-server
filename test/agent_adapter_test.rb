# frozen_string_literal: true

require_relative "test_helper"

class AgentAdapterTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @adapter = Ask::AppServer::AgentAdapter.new(
      model: "gpt-4o",
      tools: ["bash", "read"],
      system_prompt: "You are a test assistant."
    )
  end

  def test_start_session_returns_id
    session_id = @adapter.start_session
    assert session_id, "should return a session ID"
    assert_equal @adapter.session_id, session_id
  end

  def test_session_has_translator
    @adapter.start_session
    assert @adapter.translator, "should have an event translator"
  end

  def test_start_session_emits_session_created
    @adapter.start_session
    event = @adapter.translator.pending_events.last
    assert_equal "session.created", event.type
    assert_equal @adapter.session_id, event.payload["sessionId"]
  end

  def test_close_emits_session_ended
    @adapter.start_session
    @adapter.close!

    event = @adapter.translator.pending_events.last
    assert_equal "session.ended", event.type
    assert_equal @adapter.session_id, event.payload["sessionId"]
    assert_equal "closed", event.payload["reason"]
  end

  # ── Interactions (approvals) ───────────────────────────────────────────

  def test_pending_interactions_lists_queue_actions
    session, queue = session_with_approval_queue
    @adapter.resume(session)
    queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" }, message: "dangerous")

    interactions = @adapter.pending_interactions
    assert_equal 1, interactions.size
    interaction = interactions[0]
    assert_instance_of Ask::SessionProtocol::Interactions::Interaction, interaction
    assert_equal "act_1", interaction.id
    assert_equal "approval", interaction.kind
    assert_equal "pending", interaction.status
    assert_equal "bash", interaction.payload["toolName"]
    assert_equal({ "command" => "ls" }, interaction.payload["args"])
  end

  def test_approve_interaction_resolves_action
    session, queue = session_with_approval_queue
    @adapter.resume(session)
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    assert @adapter.approve_interaction("act_1")
    assert_empty @adapter.pending_interactions
  end

  def test_reject_interaction_resolves_action
    session, queue = session_with_approval_queue
    @adapter.resume(session)
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    assert @adapter.reject_interaction("act_1")
    assert_empty @adapter.pending_interactions
  end

  def test_approve_unknown_interaction_returns_false
    session, _queue = session_with_approval_queue
    @adapter.resume(session)

    refute @adapter.approve_interaction("act_999")
    refute @adapter.approve_interaction("bogus")
  end

  def test_approve_all_interactions
    session, queue = session_with_approval_queue
    @adapter.resume(session)
    queue.submit(tool_call_id: "call-1", tool_name: "bash")
    queue.submit(tool_call_id: "call-2", tool_name: "write")

    assert_equal 2, @adapter.approve_all_interactions
    assert_empty @adapter.pending_interactions
  end

  def test_reject_all_interactions
    session, queue = session_with_approval_queue
    @adapter.resume(session)
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    assert_equal 1, @adapter.reject_all_interactions
  end

  def test_interactions_without_approval_queue_are_empty
    session = fake_agent_session
    session.stubs(:approval_queue).returns(nil)
    @adapter.resume(session)

    assert_empty @adapter.pending_interactions
    refute @adapter.approve_interaction("act_1")
    assert_equal 0, @adapter.approve_all_interactions
  end

  # ── Plan ───────────────────────────────────────────────────────────────

  def test_plan_approve_and_reject
    session, plan_queue = session_with_plan_queue
    @adapter.resume(session)
    plan_queue.submit(tool_call_id: "plan-call", tool_name: "exit_plan_mode", args: { "plan" => "Do the thing" })

    assert @adapter.plan_approve
    assert_empty plan_queue.pending_actions
  end

  def test_plan_approve_without_pending_plan_returns_false
    session, _plan_queue = session_with_plan_queue
    @adapter.resume(session)

    refute @adapter.plan_approve
    refute @adapter.plan_reject
  end

  # ── Send semantics ─────────────────────────────────────────────────────

  def test_send_message_returns_steered_status
    @adapter.start_session
    # Run in a thread: the real session would attempt an LLM call, so stub.
    @adapter.session.stubs(:run).returns("done")
    @adapter.session.stubs(:queued_steers).returns(0)
    @adapter.session.stubs(:turn_id).returns("turn-1")

    result = @adapter.send_message("Hello")
    assert_equal "steered", result[:status]
    assert_equal "turn-1", result[:turn_id]
    @adapter.wait_for_turn(timeout: 2)
  end

  def test_default_tools
    adapter = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    assert adapter.send(:default_tools).length >= 5, "should have default tools"
  end

  def test_resolve_tool_by_name
    bash = @adapter.send(:resolve_tool_by_name, "bash")
    assert bash.is_a?(Ask::Tools::Bash)

    read = @adapter.send(:resolve_tool_by_name, "read")
    assert read.is_a?(Ask::Tools::Read)
  end

  def test_resolve_tool_from_the_global_registry
    klass = Class.new(Ask::Tool) do
      description "Deployment-registered tool"
      name "board_tool"
      def execute; "ok"; end
    end
    Ask::Tools.register(klass)

    tool = @adapter.send(:resolve_tool_by_name, "board_tool")
    assert tool.is_a?(klass), "preload-registered tools resolve from the global registry"
  end

  def test_resolve_unknown_tool_raises
    assert_raises(ArgumentError) do
      @adapter.send(:resolve_tool_by_name, "nonexistent_tool")
    end
  end

  def test_initial_state
    refute @adapter.running
    assert @adapter.idle?
    assert_nil @adapter.session_id
  end

  def test_abort_turn_when_not_running
    @adapter.start_session
    @adapter.abort_turn!  # Should not raise
    assert true
  end

  def test_double_start_session_creates_new
    id1 = @adapter.start_session
    # Starting a new adapter again would be a fresh session
    adapter2 = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    id2 = adapter2.start_session
    refute_equal id1, id2, "should create different session IDs"
  end

  def test_pending_events_initial_is_session_created
    @adapter.start_session
    events = @adapter.pending_events
    assert_equal 1, events.size
    assert_equal "session.created", events[0].type
  end

  def test_events_after_filters_initial_event
    @adapter.start_session
    assert_empty @adapter.events_after(0).select { |e| e.seq > 1 }
    assert_empty @adapter.events_after(1)
  end

  def test_send_message_requires_session
    assert_raises(RuntimeError, "Session not started") do
      @adapter.send_message("hello")
    end
  end

  def test_drain_events
    @adapter.start_session
    drained = @adapter.drain_events
    assert_equal 1, drained.size
    assert_equal "session.created", drained[0].type
    assert_empty @adapter.drain_events
  end

  def test_resume_re_attaches_handler
    @adapter.start_session
    session = @adapter.session

    adapter2 = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    adapter2.resume(session)
    assert_equal session.id, adapter2.session_id
    assert adapter2.translator
  end

  private

  # A fake session whose approval queue is a real, inert ApprovalQueue
  # (no session callbacks wired): queue mechanics are exercised without
  # triggering tool execution or LLM calls.
  def session_with_approval_queue
    queue = Ask::Agent::ApprovalQueue.new
    session = fake_agent_session
    session.stubs(:approval_queue).returns(queue)
    session.stubs(:plan_queue).returns(Ask::Agent::ApprovalQueue.new)
    [session, queue]
  end

  def session_with_plan_queue
    plan_queue = Ask::Agent::ApprovalQueue.new
    session = fake_agent_session
    session.stubs(:approval_queue).returns(Ask::Agent::ApprovalQueue.new)
    session.stubs(:plan_queue).returns(plan_queue)
    [session, plan_queue]
  end
end
