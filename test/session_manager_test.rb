# frozen_string_literal: true

require_relative "test_helper"

class SessionManagerTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @manager = Ask::AppServer::SessionManager.new
  end

  def test_create_session
    session_id = @manager.create_session(
      workspace_path: "/tmp",
      model: "gpt-4o",
      tools: ["bash", "read"]
    )

    assert session_id, "should return a session ID"
    assert session_id.is_a?(String), "session ID should be a string"
    refute_empty session_id

    adapter = @manager.get(session_id)
    assert adapter, "adapter should exist"
    assert_equal session_id, adapter.session_id
  end

  def test_create_session_with_defaults
    session_id = @manager.create_session
    assert session_id, "should create with defaults"
  end

  def test_create_and_destroy
    session_id = @manager.create_session
    assert @manager.destroy_session(session_id), "destroy should return true"

    assert_nil @manager.get(session_id), "session should be gone"
    assert_equal 0, @manager.store.count
  end

  def test_destroy_nonexistent_returns_false
    refute @manager.destroy_session("nonexistent")
  end

  def test_list_sessions
    sid1 = @manager.create_session(workspace_path: "/tmp")
    sid2 = @manager.create_session(workspace_path: "/tmp")

    list = @manager.list_sessions
    assert list.length >= 2
    session_ids = list.map { |s| s[:sessionId] }
    assert_includes session_ids, sid1
    assert_includes session_ids, sid2
  end

  def test_send_message_requires_session
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.send_message("nonexistent", "hello")
    end
  end

  def test_subscribe
    session_id = @manager.create_session

    result = @manager.subscribe(session_id, delivery_kind: "replay")
    assert_equal session_id, result[:subscription][:sessionId]
    assert_equal "replay", result[:subscription][:deliveryKind]

    assert @manager.subscribed?(session_id)
  end

  def test_subscribe_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.subscribe("nonexistent")
    end
  end

  def test_get_events_starts_with_session_created
    session_id = @manager.create_session
    result = @manager.get_events(session_id, after_seq: 0)
    assert_equal session_id, result[:sessionId]
    assert_equal 1, result[:events].size
    assert_equal "session.created", result[:events][0].type

    assert_empty @manager.get_events(session_id, after_seq: 1)[:events]
  end

  def test_get_events_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.get_events("nonexistent", after_seq: 0)
    end
  end

  def test_read_workspace_state
    state = @manager.read_workspace_state
    assert state[:settings]
    assert state.dig(:settings, :model, :current, :modelId), "should have model"
    assert state.dig(:settings, :model, :current, :providerId), "should have provider"
    assert_equal "require", state.dig(:workspace, :mode)
  end

  # ── Send semantics ─────────────────────────────────────────────────────

  def test_send_message_returns_status
    session_id = @manager.create_session
    adapter = @manager.get(session_id)
    adapter.session.stubs(:run).returns("done")
    adapter.session.stubs(:queued_steers).returns(0)
    adapter.session.stubs(:turn_id).returns("turn-1")

    result = @manager.send_message(session_id, "Hello")
    assert result[:accepted]
    assert_equal "steered", result[:status]
    assert_equal "turn-1", result[:turnId]
    adapter.wait_for_turn(timeout: 2)
  end

  def test_send_message_stale_expected_turn
    session_id = @manager.create_session
    adapter = @manager.get(session_id)
    adapter.stubs(:send_message).with("Late message", expected_turn_id: "old-turn")
      .returns({ status: "stale", turn_id: "other-turn" })

    result = @manager.send_message(session_id, "Late message", expected_turn_id: "old-turn")
    refute result[:accepted]
    assert_equal "stale", result[:status]
  end

  # ── Interactions ───────────────────────────────────────────────────────

  def test_interaction_controls_delegate_to_adapter
    session_id = @manager.create_session
    adapter = @manager.get(session_id)
    interaction = Ask::SessionProtocol::Interactions.interaction(
      id: "act_1", kind: "approval", payload: { "toolName" => "bash" }
    )
    adapter.stubs(:pending_interactions).returns([interaction])
    adapter.stubs(:approve_interaction).with("act_1").returns(true)
    adapter.stubs(:reject_interaction).with("act_2").returns(true)
    adapter.stubs(:approve_all_interactions).returns(3)
    adapter.stubs(:reject_all_interactions).returns(1)
    adapter.stubs(:plan_approve).returns(true)
    adapter.stubs(:plan_reject).returns(true)

    assert_equal [interaction], @manager.pending_interactions(session_id)
    assert @manager.approve_interaction(session_id, "act_1")
    assert @manager.reject_interaction(session_id, "act_2")
    assert_equal 3, @manager.approve_all_interactions(session_id)
    assert_equal 1, @manager.reject_all_interactions(session_id)
    assert @manager.plan_approve(session_id)
    assert @manager.plan_reject(session_id)
  end

  def test_interaction_controls_require_session
    assert_raises(Ask::AppServer::SessionNotFound) { @manager.pending_interactions("nope") }
    assert_raises(Ask::AppServer::SessionNotFound) { @manager.approve_interaction("nope", "act_1") }
    assert_raises(Ask::AppServer::SessionNotFound) { @manager.plan_approve("nope") }
  end

  # ── Close ──────────────────────────────────────────────────────────────

  def test_close_session
    session_id = @manager.create_session
    adapter = @manager.get(session_id)
    adapter.session.stubs(:delete)
    adapter.session.stubs(:abort)

    assert @manager.close_session(session_id)
    assert_nil @manager.get(session_id)
  end
end
