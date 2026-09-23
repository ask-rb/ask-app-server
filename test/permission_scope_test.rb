# frozen_string_literal: true

require_relative "test_helper"

class PermissionScopeTest < Minitest::Test
  def setup
    @manager = Ask::AppServer::SessionManager.new
    @server = Ask::AppServer::Server.new(session_manager: @manager)
    @output = StringIO.new
    @output.sync = true
    @connection = @server.add_connection(Ask::AppServer::Connection.new(StringIO.new(""), @output))
    @original_stdout = $stdout
    $stdout = @output
    @original_stderr = $stderr
    $stderr = StringIO.new
    @read_index = 0
  end

  def teardown
    $stdout = @original_stdout
    $stderr = @original_stderr
  end

  # 1. Event offer: approval.required advertises allowedScopes [once, session]
  def test_approval_required_offers_allowed_scopes
    session_id = @manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
    adapter = @manager.get(session_id)
    queue = adapter.session.approval_queue
    assert queue, "session should have an approval queue"

    queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" })

    required = adapter.translator.pending_events.find { |e| e.type == "approval.required" }
    assert required, "approval.required should be emitted"
    assert_equal %w[once session], required.payload["allowedScopes"]
  end

  # Pending interaction payloads also advertise allowedScopes
  def test_pending_interactions_advertise_allowed_scopes
    session_id = @manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
    adapter = @manager.get(session_id)
    adapter.session.approval_queue.submit(tool_call_id: "call-1", tool_name: "bash")

    interactions = @manager.pending_interactions(session_id)
    assert_equal 1, interactions.size
    assert_equal %w[once session], interactions.first.payload["allowedScopes"]
  end

  # 2. Session scope round-trip through request handling
  def test_session_scope_round_trip_through_request_handling
    session_id = @manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
    adapter = @manager.get(session_id)
    queue = adapter.session.approval_queue
    adapter.session.define_singleton_method(:run_follow_up) { true }
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    dispatch("interaction/approve",
             { "sessionId" => session_id, "interactionId" => "act_1", "scope" => "session" }, id: 2)
    response = read_response
    assert response.dig("result", "approved"), "approve should succeed: #{response.inspect}"

    action = queue[1]
    assert action.approved?
    assert_equal :session, action.resolution_scope
    assert adapter.session.session_grants.granted?("bash")

    updated = adapter.translator.pending_events.reverse.find { |e| e.type == "approval.updated" }
    assert updated, "approval.updated should be emitted"
    assert_equal "approved", updated.payload["status"]
    assert_equal "session", updated.payload["scope"]
  end

  # 3. Old request default once (backward compatible omitted scope)
  def test_old_approve_request_defaults_to_once
    session_id = @manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
    adapter = @manager.get(session_id)
    queue = adapter.session.approval_queue
    adapter.session.define_singleton_method(:run_follow_up) { true }
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    dispatch("interaction/approve",
             { "sessionId" => session_id, "interactionId" => "act_1" }, id: 2)
    response = read_response
    assert response.dig("result", "approved"), "approve without scope should succeed"

    action = queue[1]
    assert action.approved?
    assert_equal :once, action.resolution_scope
    refute adapter.session.session_grants.granted?("bash")

    updated = adapter.translator.pending_events.reverse.find { |e| e.type == "approval.updated" }
    assert updated
    assert_equal "approved", updated.payload["status"]
    refute updated.payload.key?("scope"), "default once scope is omitted from approval.updated"
  end

  # 4. Denial feedback propagates to the queue and approval.updated
  def test_denial_feedback_round_trip
    adapter, queue, session_id = adapter_with_queued_action

    dispatch("interaction/reject",
             { "sessionId" => session_id, "interactionId" => "act_1",
               "feedback" => "Use a read-only alternative" }, id: 2)
    response = read_response
    assert response.dig("result", "rejected"), "reject should succeed: #{response.inspect}"

    action = queue[1]
    assert action.rejected?
    assert_equal "Use a read-only alternative", action.feedback

    updated = adapter.translator.pending_events.reverse.find { |e| e.type == "approval.updated" }
    assert updated
    assert_equal "rejected", updated.payload["status"]
    assert_equal "Use a read-only alternative", updated.payload["feedback"]
  end

  # 5. Project scope is rejected explicitly, never silently downgraded
  def test_project_scope_rejected_explicitly
    adapter, queue, session_id = adapter_with_queued_action

    dispatch("interaction/approve",
             { "sessionId" => session_id, "interactionId" => "act_1", "scope" => "project" }, id: 2)
    response = read_response
    assert response["error"], "project scope must error, not downgrade: #{response.inspect}"
    assert_equal(-32602, response.dig("error", "code"))
    assert_match(/project/i, response.dig("error", "message"))

    action = queue[1]
    assert action.pending?, "rejected scope must leave the action pending (no silent downgrade)"
  end

  def test_non_string_scope_is_rejected_as_invalid_request
    _adapter, queue, session_id = adapter_with_queued_action

    dispatch("interaction/approve",
             { "sessionId" => session_id, "interactionId" => "act_1", "scope" => 123 }, id: 2)
    response = read_response

    assert_equal(-32602, response.dig("error", "code"))
    assert_match(/scope/i, response.dig("error", "message"))
    assert queue[1].pending?
  end

  private

  def adapter_with_queued_action
    session_id = @manager.create_session(workspace_path: "/tmp", model: "gpt-4o")
    adapter = @manager.get(session_id)
    queue = adapter.session.approval_queue
    adapter.session.instance_variable_get(:@pending_tools)["call-1"] = {
      tool_name: "bash", message: "Pending approval", status: "pending", tool_call_id: "call-1"
    }
    adapter.session.define_singleton_method(:run_follow_up) { true }
    queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "echo test" })
    [adapter, queue, session_id]
  end

  def dispatch(method, params, id: nil)
    msg = { "method" => method, "params" => params }
    msg["id"] = id if id
    @server.dispatch(msg, @connection)
  end

  def read_response
    line = @output.string.lines.drop(@read_index || 0).first
    @read_index = (@read_index || 0) + 1
    line ? JSON.parse(line.strip) : nil
  end
end
