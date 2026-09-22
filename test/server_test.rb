# frozen_string_literal: true

require_relative "test_helper"

class ServerTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @session_manager = Ask::AppServer::SessionManager.new
    @server = Ask::AppServer::Server.new(session_manager: @session_manager)

    # Each test dispatches through a Connection writing to a captured StringIO.
    @output = StringIO.new
    @output.sync = true
    @connection = @server.add_connection(Ask::AppServer::Connection.new(StringIO.new(""), @output))
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

  # ── Host-side contract enforcement ─────────────────────────────────────

  def test_invalid_params_rejected_by_contract
    handle("session/send", { sessionId: "s1", content: 42 }, id: 1)
    response = read_response

    assert_equal(-32602, response.dig("error", "code"))
    assert_match(/content/, response.dig("error", "message"))
  end

  def test_invalid_delivery_kind_rejected_by_contract
    session_id = create_test_session
    clear_output!

    handle("session/subscribe", { sessionId: session_id, deliveryKind: "teleport" }, id: 2)
    response = read_response

    assert_equal(-32602, response.dig("error", "code"))
  end

  # ── Cursor-based event delivery ────────────────────────────────────────

  def test_push_pending_delivers_events_after_connection_cursor
    session_id = create_test_session
    adapter = @session_manager.get(session_id)
    clear_output!

    # Subscribe: the connection cursor starts at 0, so the next push
    # delivers the session.created event from the log.
    handle("session/subscribe", { sessionId: session_id }, id: 2)
    read_response
    clear_output!

    @server.push_pending

    line = read_response
    assert line, "subscribed connection should receive a session/event notification"
    assert_equal "session/event", line["method"]
    assert_equal "session.created", line.dig("params", "event", "type")

    # Cursor advanced: a second push delivers nothing new.
    clear_output!
    @server.push_pending
    assert_nil read_response
  end

  def test_push_pending_delivers_replay_from_after_seq
    session_id = create_test_session
    clear_output!

    # Subscribe after seq 1 (session.created already seen): no replay.
    handle("session/subscribe", { sessionId: session_id, afterSeq: 1 }, id: 2)
    read_response
    clear_output!

    @server.push_pending
    assert_nil read_response
  end

  def test_push_pending_respects_connection_isolation
    session_id = create_test_session
    adapter = @session_manager.get(session_id)

    # Connection A subscribes; connection B does not.
    output_b = StringIO.new
    conn_b = Ask::AppServer::Connection.new(StringIO.new(""), output_b)
    handle("session/subscribe", { sessionId: session_id }, id: 2)
    read_response
    clear_output!

    @server.push_pending
    assert read_response, "connection A should receive events"
    assert output_b.string.empty?, "connection B should receive nothing"
  end

  def test_push_pending_survives_a_disconnected_watcher
    # A fresh server so connection order is controlled: the dead
    # watcher is registered FIRST — before the fix its EPIPE aborted
    # the whole pass and the live watcher never woke.
    manager = Ask::AppServer::SessionManager.new
    server = Ask::AppServer::Server.new(session_manager: manager)
    session_id = manager.create_session(workspace_path: "/tmp", model: "gpt-4o")

    dead = server.add_connection(
      Ask::AppServer::Connection.new(StringIO.new(""), DeadWatcherOutput.new)
    )
    dead.subscribe(session_id, after_seq: 0)

    live_output = StringIO.new
    live = server.add_connection(
      Ask::AppServer::Connection.new(StringIO.new(""), live_output)
    )
    live.subscribe(session_id, after_seq: 0)

    server.push_pending

    notifications = live_output.string.lines.map { |line| JSON.parse(line) }
    assert notifications.any? { |n| n["method"] == "session/event" },
           "a live watcher still receives events after a peer disconnects"
    assert_equal 0, dead.cursor(session_id),
                 "the dead watcher's cursor does not advance past undelivered events"

    # Subsequent passes keep working: the dead watcher never breaks
    # delivery for anyone (its own events redeliver, others advance).
    server.push_pending
    assert_equal 1, live.cursor(session_id)
    assert_equal 0, dead.cursor(session_id)
  end

  # ── Failure events reach subscribed wire watchers ─────────────────────

  # Model stream drops, run failures, and disconnects all funnel through
  # the adapter's terminal-failure path. A subscribed watcher must
  # receive each as a session/event notification carrying the session
  # (envelope), the turn identity, and the error — the triple a client
  # needs to settle the run instead of waiting on a ghost forever.
  def test_model_stream_drop_reaches_wire_watcher
    session_id, failure, started = capture_wire_failure(announce_turn: true) do |session|
      # The run returns but the turn never completed: the stream dropped.
      session.stubs(:run).returns("done")
    end

    assert_equal session_id, failure.dig("params", "sessionId")
    assert started, "the dropped turn announced itself on the wire"
    assert_equal started.dig("params", "event", "payload", "turnId"),
                 failure.dig("params", "event", "payload", "turnId"),
                 "the failure correlates to the dropped turn by turnId"
    assert_match(/stream ended without completing/,
                 failure.dig("params", "event", "payload", "error"))
  end

  def test_run_failure_reaches_wire_watcher
    session_id, failure, = capture_wire_failure do |session|
      # The run dies before turn.started: no turn announced itself, but
      # the watcher still gets a fresh, protocol-valid identity.
      session.stubs(:run).raises(RuntimeError, "provider exploded")
    end

    assert_equal session_id, failure.dig("params", "sessionId")
    refute_empty failure.dig("params", "event", "payload", "turnId"),
                 "a run that dies before turn.started still carries identity"
    assert_match(/provider exploded/,
                 failure.dig("params", "event", "payload", "error"))
  end

  def test_disconnect_reaches_wire_watcher
    session_id, failure, started = capture_wire_failure(announce_turn: true) do |session|
      # The model connection drops mid-run: the provider raises EOF.
      session.stubs(:run).raises(EOFError, "end of file reached")
    end

    assert_equal session_id, failure.dig("params", "sessionId")
    assert started, "the interrupted turn announced itself on the wire"
    assert_equal started.dig("params", "event", "payload", "turnId"),
                 failure.dig("params", "event", "payload", "turnId")
    assert_match(/end of file reached/,
                 failure.dig("params", "event", "payload", "error"))
  end

  # An output whose writes fail the way a disconnected socket does.
  class DeadWatcherOutput
    def puts(*)
      raise Errno::EPIPE
    end

    def flush; end
  end

  private

  def handle(method, params = {}, id: nil)
    msg = { "method" => method, "params" => params }
    msg["id"] = id if id
    @server.dispatch(msg, @connection)
  end

  def read_response
    line = @output.string.lines.drop(@read_index || 0).first
    @read_index = (@read_index || 0) + 1
    line ? JSON.parse(line.strip) : nil
  end

  def clear_output!
    # The same logical client keeps its delivery cursors across an output
    # swap; only the sink changes.
    previous_subscriptions = @connection.subscriptions.dup
    @output = StringIO.new
    @output.sync = true
    $stdout = @output
    @connection = @server.add_connection(Ask::AppServer::Connection.new(StringIO.new(""), @output))
    previous_subscriptions.each { |sid, seq| @connection.subscribe(sid, after_seq: seq) }
    @read_index = 0
  end

  def create_test_session
    @session_manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
  end

  # Subscribe a watcher, drive one terminal run failure through the
  # adapter, and return [session_id, turn.failed notification,
  # turn.started notification]. Asserts the run settles before the
  # delivery pass — the wake watchers depend on — so the notification
  # observed here is the one a real client receives.
  def capture_wire_failure(announce_turn: false)
    session_id = create_test_session
    adapter = @session_manager.get(session_id)

    handle("session/subscribe", { sessionId: session_id }, id: 2)
    read_response
    clear_output!

    # Announce a turn when the scenario started one (stream drop,
    # mid-run disconnect): the failure must correlate by that turnId.
    adapter.session.emit(Ask::Agent::Events::TurnStart.new) if announce_turn
    yield adapter.session

    handle("session/send", { sessionId: session_id, content: "Hello" }, id: 3)
    read_response
    assert adapter.wait_for_turn(timeout: 2), "the run thread must settle"
    refute adapter.running, "watchers wake with the run already settled"

    @server.push_pending

    notifications = @output.string.lines.map { |line| JSON.parse(line.strip) }
    failure = notifications.find { |n| n.dig("params", "event", "type") == "turn.failed" }
    assert failure, "the subscribed watcher must be pushed turn.failed"

    started = notifications.find { |n| n.dig("params", "event", "type") == "turn.started" }
    [session_id, failure, started]
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
