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
    assert_equal "ask-app-server", response.dig("result", "serverInfo", "name")
    assert response.dig("result", "capabilities", "sessionManagement")
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

    handle("session/subscribe", { sessionId: session_id, deliveryKind: "web-remote-replayable" }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "subscribed")
  end

  def test_session_send
    session_id = create_test_session
    clear_output!

    handle("session/send", { sessionId: session_id, content: "Hello?" }, id: 2)
    response = read_response

    assert response
    assert response.dig("result", "accepted")
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
end
