# frozen_string_literal: true

require_relative "test_helper"

class ServerTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @session_manager = Ask::AppServer::SessionManager.new
    @server = Ask::AppServer::Server.new(session_manager: @session_manager)

    # Capture stdout with a StringIO
    @output = StringIO.new
    @output.sync = true
    @original_stdout = $stdout
    $stdout = @output

    # Also suppress stderr noise
    @original_stderr = $stderr
    $stderr = StringIO.new
  end

  def teardown
    $stdout = @original_stdout
    $stderr = @original_stderr
  end

  def test_initialize_handshake
    handle("initialize", { clientName: "test" }, id: 1)
    response = read_response

    assert response, "should get a response"
    assert response["result"]
    assert_equal "ask-app-server", response.dig("result", "server", "name")
    assert_equal Ask::SessionProtocol::PROTOCOL_VERSION, response.dig("result", "protocolVersion")
    capabilities = response.dig("result", "capabilities")
    assert_includes capabilities, "sessionManagement"
    assert_includes capabilities, "interactions"
    assert_includes capabilities, "planMode"
  end

  def test_session_create
    handle("session/create", {
      workspace: { workspacePath: "/tmp/test-project" },
      model: "gpt-4o"
    }, id: 1)

    response = read_response
    assert response
    assert response.dig("result", "session", "sessionId")
  end

  def test_session_create_and_list
    handle("session/create", { workspace: { workspacePath: "/tmp/a" }, model: "gpt-4o" }, id: 1)
    session_id = read_response.dig("result", "session", "sessionId")

    handle("session/list", { limit: 10 }, id: 2)
    response = read_response

    sessions = response.dig("result", "sessions")
    assert sessions, "should have sessions list"
    assert sessions.any? { |s| s["sessionId"] == session_id }
  end

  def test_session_resume
    session_id = create_test_session
    clear_output!

    handle("session/resume", { sessionId: session_id }, id: 2)
    response = read_response

    assert response
    assert_equal session_id, response.dig("result", "sessionId")
    assert response.dig("result", "idle")
  end

  def test_session_resume_nonexistent
    handle("session/resume", { sessionId: "nonexistent" }, id: 1)
    response = read_response

    assert response
    assert response["error"]
    assert_equal(-32004, response.dig("error", "code"))
  end

  def test_session_subscribe
    session_id = create_test_session
    clear_output!

    handle("session/subscribe", { sessionId: session_id, deliveryKind: "replay" }, id: 2)
    response = read_response

    assert response
    assert_equal session_id, response.dig("result", "subscription", "sessionId")
    assert_equal "replay", response.dig("result", "subscription", "deliveryKind")
  end

  def test_session_subscribe_with_snapshot
    session_id = create_test_session
    clear_output!

    handle("session/subscribe", { sessionId: session_id, includeSnapshot: true, afterSeq: 0 }, id: 2)
    response = read_response

    events = response.dig("result", "snapshot")
    assert events
    assert_equal "session.created", events[0]["type"]
    assert_equal session_id, events[0]["payload"]["sessionId"]
  end

  def test_session_send
    session_id = create_test_session
    clear_output!

    handle("session/send", { sessionId: session_id, content: "Hello?" }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "accepted")
    assert_equal "steered", response.dig("result", "status")
  end

  def test_session_send_no_session_id
    handle("session/send", { content: "hello" }, id: 1)
    response = read_response

    assert response
    assert response["error"]
  end

  def test_session_events
    session_id = create_test_session
    clear_output!

    handle("session/events", { sessionId: session_id, afterSeq: 0 }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "events")
  end

  def test_session_abort
    session_id = create_test_session
    clear_output!

    handle("session/abort", { sessionId: session_id }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "aborted")
  end

  def test_workspace_read_state
    handle("workspace/readState", { workspace: { workspacePath: "/tmp" } }, id: 1)
    response = read_response

    assert response
    assert_equal "require", response.dig("result", "workspace", "mode")
    assert response.dig("result", "settings", "model", "current", "modelId")
  end

  def test_unknown_method_returns_error
    handle("unknown/method", {}, id: 1)
    response = read_response

    assert response
    assert response["error"]
    assert_equal(-32601, response.dig("error", "code"))
  end

  def test_server_running_state
    refute @server.running?
  end

  def test_multiple_requests_get_correct_ids
    handle("initialize", { clientName: "a" }, id: 1)
    handle("initialize", {}, id: 2)

    resp1 = read_response
    resp2 = read_response

    assert resp1
    assert resp2
    assert_equal 1, resp1["id"]
    assert_equal 2, resp2["id"]
  end

  def test_no_id_returns_no_response
    handle("initialize", {})  # no id — notification, no response
    assert @output.string.empty? || @output.string.strip.empty?
  end

  # --- Ping ---

  def test_ping_returns_status
    handle("ping", {}, id: 1)
    response = read_response

    assert response
    assert_equal "ok", response.dig("result", "status")
    assert response.dig("result", "version")
    assert response.dig("result", "sessions")&.is_a?(Integer)
  end

  def test_ping_returns_uptime
    handle("ping", {}, id: 1)
    response = read_response

    assert response
    uptime = response.dig("result", "uptime")
    assert uptime.is_a?(Integer), "uptime should be an integer"
    assert_equal 0, uptime, "uptime should be 0 since server hasn't started"
  end

  def test_ping_with_active_session
    create_test_session

    handle("ping", {}, id: 1)
    response = read_response

    assert response
    assert_equal 1, response.dig("result", "sessions"), "should report 1 active session"
  end

  def test_ping_reports_protocol_version
    handle("ping", {}, id: 1)
    response = read_response
    assert_equal Ask::SessionProtocol::PROTOCOL_VERSION, response.dig("result", "protocolVersion")
  end

  # ── Session close ──────────────────────────────────────────────────────

  def test_session_close
    session_id = create_test_session
    clear_output!

    handle("session/close", { sessionId: session_id }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "closed")
    assert_nil @session_manager.get(session_id)
  end

  def test_session_close_nonexistent_errors
    handle("session/close", { sessionId: "nope" }, id: 1)
    response = read_response
    assert_equal(-32004, response.dig("error", "code"))
  end

  # ── Interactions ───────────────────────────────────────────────────────

  def test_interaction_list
    session_id = create_test_session
    adapter = @session_manager.get(session_id)
    interaction = Ask::SessionProtocol::Interactions.interaction(
      id: "act_1", kind: "approval",
      payload: { "toolName" => "bash", "args" => { "command" => "ls" } }
    )
    adapter.stubs(:pending_interactions).returns([interaction])
    clear_output!

    handle("interaction/list", { sessionId: session_id }, id: 2)
    response = read_response

    interactions = response.dig("result", "interactions")
    assert_equal 1, interactions.size
    assert_equal "act_1", interactions[0]["id"]
    assert_equal "approval", interactions[0]["kind"]
    assert_equal "bash", interactions[0]["payload"]["toolName"]
  end

  def test_interaction_approve
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:approve_interaction).with("act_1").returns(true)
    clear_output!

    handle("interaction/approve", { sessionId: session_id, interactionId: "act_1" }, id: 2)
    response = read_response

    assert response.dig("result", "approved")
    assert_equal "act_1", response.dig("result", "interactionId")
  end

  def test_interaction_approve_not_found_errors
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:approve_interaction).returns(false)
    clear_output!

    handle("interaction/approve", { sessionId: session_id, interactionId: "act_999" }, id: 2)
    response = read_response

    assert_equal(-32006, response.dig("error", "code"))
    assert_match(/not found/, response.dig("error", "message"))
  end

  def test_interaction_reject
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:reject_interaction).with("act_1").returns(true)
    clear_output!

    handle("interaction/reject", { sessionId: session_id, interactionId: "act_1" }, id: 2)
    response = read_response

    assert response.dig("result", "rejected")
  end

  def test_interaction_approve_all
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:approve_all_interactions).returns(2)
    clear_output!

    handle("interaction/approve-all", { sessionId: session_id }, id: 2)
    response = read_response

    assert_equal 2, response.dig("result", "approved")
  end

  def test_interaction_reject_all
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:reject_all_interactions).returns(1)
    clear_output!

    handle("interaction/reject-all", { sessionId: session_id }, id: 2)
    response = read_response

    assert_equal 1, response.dig("result", "rejected")
  end

  def test_interaction_respond_not_implemented
    session_id = create_test_session
    clear_output!

    handle("interaction/respond", { sessionId: session_id, interactionId: "in_1", response: "yes" }, id: 2)
    response = read_response

    assert_equal(-32009, response.dig("error", "code"))
  end

  def test_interaction_requires_session
    handle("interaction/list", {}, id: 1)
    response = read_response
    assert response.dig("error")
  end

  # ── Plan ───────────────────────────────────────────────────────────────

  def test_plan_approve
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:plan_approve).returns(true)
    clear_output!

    handle("plan/approve", { sessionId: session_id }, id: 2)
    response = read_response

    assert response.dig("result", "approved")
  end

  def test_plan_approve_no_pending_errors
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:plan_approve).returns(false)
    clear_output!

    handle("plan/approve", { sessionId: session_id }, id: 2)
    response = read_response

    assert_equal(-32007, response.dig("error", "code"))
  end

  def test_plan_reject
    session_id = create_test_session
    @session_manager.get(session_id).stubs(:plan_reject).returns(true)
    clear_output!

    handle("plan/reject", { sessionId: session_id }, id: 2)
    response = read_response

    assert response.dig("result", "rejected")
  end

  def test_interaction_request_permission_query
    handle("interaction/requestPermission", {}, id: 1)
    response = read_response

    assert response
    assert_equal "require", response.dig("result", "mode")
  end

  private

  def handle(method, params = {}, id: nil)
    msg = { "method" => method, "params" => params }
    msg["id"] = id if id
    @server.send(:handle_message, msg)
  end

  def read_response
    line = @output.string.lines.drop(@read_index || 0).first
    @read_index = (@read_index || 0) + 1
    line ? JSON.parse(line.strip) : nil
  end

  def clear_output!
    @output = StringIO.new
    @output.sync = true
    $stdout = @output
    @read_index = 0
  end

  def create_test_session
    @session_manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
  end

  public

  def test_session_artifacts_handlers
    handle("session/create", { model: "gpt-4o" }, id: 1)
    response = read_response
    session_id = response.dig("result", "session", "sessionId")

    # Enable artifacts on the underlying session (as artifacts: true would).
    adapter = @session_manager.get(session_id)
    agent = adapter.session
    agent.instance_variable_set(:@artifact_store, Ask::Agent::ArtifactStore.new(state: Ask::State::Memory.new))
    record = agent.artifact_store.store(agent.id, filename: "report.csv", mime_type: "text/csv", content: "a,b\n1,2\n")

    handle("session/artifacts", { sessionId: session_id }, id: 2)
    artifacts_response = read_response
    assert_equal 1, artifacts_response.dig("result", "artifacts").size
    assert_equal "report.csv", artifacts_response.dig("result", "artifacts", 0, "filename")
    refute artifacts_response.dig("result", "artifacts", 0).key?("content")

    handle("session/artifact/get", { sessionId: session_id, artifactId: record[:id] }, id: 3)
    get_response = read_response
    assert_equal "a,b\n1,2\n", get_response.dig("result", "artifact", "content")
  end

  def test_session_artifacts_requires_session
    handle("session/artifacts", {}, id: 1)
    response = read_response
    assert response.dig("error")
  end
end
