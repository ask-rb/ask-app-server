# frozen_string_literal: true

require_relative "test_helper"

# Integration with the durable ask-session layer: Ask::Session::Host is
# the event source of truth for create/send/replay, while protocol
# translation stays at the app-server boundary (EventTranslator) and the
# wire contract is unchanged.
class SessionHostIntegrationTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @manager = Ask::AppServer::SessionManager.new
  end

  # ── Create ─────────────────────────────────────────────────────────────

  def test_create_session_creates_durable_ask_session_record
    sid = @manager.create_session(model: "gpt-4o")

    assert_same @manager.host, @manager.get(sid).host

    record = @manager.host.session(sid)
    assert_equal sid, record.id
    assert_equal :active, record.status
    assert_equal "gpt-4o", record.metadata[:model]

    events = @manager.host.events(sid)
    assert_equal 1, events.size
    assert_equal "session.created", events.first.type
    assert_equal 1, events.first.seq
  end

  def test_manager_accepts_an_injected_host
    host = Ask::Session::Host.new
    manager = Ask::AppServer::SessionManager.new(host: host)

    sid = manager.create_session(model: "gpt-4o")

    assert_same host, manager.get(sid).host
    assert_equal :active, host.session(sid).status
  end

  # ── Send ───────────────────────────────────────────────────────────────

  def test_send_persists_wire_shaped_events_to_the_host
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)
    adapter.session.stubs(:run).returns("done")
    adapter.session.stubs(:queued_steers).returns(0)
    adapter.session.stubs(:turn_id).returns("turn-1")

    # Drive a canonical event through the session's event pipeline — the
    # same path a real run uses.
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: "Hi"))

    result = @manager.send_message(sid, "Hello")
    assert result[:accepted]
    adapter.wait_for_turn(timeout: 2)

    durable = @manager.host.events(sid)
    # A clean run appends an agent.snapshot after the wire events; the
    # snapshot is Host-internal and filtered from wire replay.
    assert_equal %w[session.created model.streaming agent.snapshot], durable.map(&:type)
    # Durable seq is the wire seq: contiguous from 1.
    assert_equal [1, 2, 3], durable.map(&:seq)
    # Protocol translation happened at the boundary: the stored payload
    # is the wire shape, not the ask-session vocabulary.
    assert_equal({ "delta" => "Hi" }, durable[1].payload)
  end

  def test_approval_events_are_durable_protocol_events
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)

    queue = Ask::Permissions::ApprovalQueue.new
    id = queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" })
    adapter.translator.approval_required(queue[id])

    events = @manager.get_events(sid, after_seq: 1)[:events]
    assert_equal ["approval.required"], events.map(&:type)
    assert_equal "act_1", events[0].payload["id"]
    assert_equal 2, events[0].seq
  end

  # ── Replay ─────────────────────────────────────────────────────────────

  def test_replay_reads_the_durable_host_log_not_the_translator_buffer
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: "a"))

    # Wipe the in-memory translator buffer: replay must not depend on it.
    adapter.drain_events
    assert_empty adapter.pending_events

    result = @manager.get_events(sid, after_seq: 0)
    assert_equal %w[session.created model.streaming], result[:events].map(&:type)
    assert_equal [1, 2], result[:events].map(&:seq)
    assert_equal({ "delta" => "a" }, result[:events][1].payload)
  end

  def test_replay_cursor_after_seq_reads_durable_events
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: "a"))
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: "b"))

    result = @manager.get_events(sid, after_seq: 2)
    assert_equal ["model.streaming"], result[:events].map(&:type)
    assert_equal [3], result[:events].map(&:seq)
    assert_equal({ "delta" => "b" }, result[:events][0].payload)
    refute result[:hasMore]
  end

  def test_server_create_send_resume_replay_over_durable_log
    server = Ask::AppServer::Server.new(session_manager: @manager)
    output = StringIO.new
    output.sync = true
    connection = server.add_connection(
      Ask::AppServer::Connection.new(StringIO.new(""), output)
    )

    server.dispatch(rpc(1, "session/create", { "model" => "gpt-4o" }), connection)
    sid = output_lines(output)[0].dig("result", "session", "sessionId")
    assert sid

    adapter = @manager.get(sid)
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: "Hi"))

    adapter.session.stubs(:run).returns("done")
    adapter.session.stubs(:queued_steers).returns(0)
    adapter.session.stubs(:turn_id).returns("turn-1")
    server.dispatch(rpc(2, "session/send", { "sessionId" => sid, "content" => "Hello" }), connection)
    assert output_lines(output)[1].dig("result", "accepted")
    adapter.wait_for_turn(timeout: 2)

    server.dispatch(rpc(3, "session/resume", { "sessionId" => sid }), connection)
    assert_equal sid, output_lines(output)[2].dig("result", "sessionId")

    server.dispatch(
      rpc(4, "session/events", { "sessionId" => sid, "afterSeq" => 0 }), connection
    )
    events = output_lines(output)[3].dig("result", "events")
    assert_equal %w[session.created model.streaming], events.map { |e| e["type"] }
    assert_equal [1, 2], events.map { |e| e["seq"] }
    assert_equal({ "delta" => "Hi" }, events[1]["payload"])

    server.dispatch(
      rpc(5, "session/subscribe",
          { "sessionId" => sid, "afterSeq" => 1, "includeSnapshot" => true }),
      connection
    )
    snapshot = output_lines(output)[4].dig("result", "snapshot")
    assert_equal ["model.streaming"], snapshot.map { |e| e["type"] }
    assert_equal 2, snapshot[0]["seq"]
  end

  # ── Close ──────────────────────────────────────────────────────────────

  def test_run_failure_is_durable_and_replayable
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)
    adapter.session.stubs(:run).raises(RuntimeError, "provider exploded")

    @manager.send_message(sid, "Hello")
    assert adapter.wait_for_turn(timeout: 2)

    # A watcher polling (or replaying after a reconnect) finds the
    # terminal failure in the durable log — not just the live buffer.
    events = @manager.get_events(sid, after_seq: 1)[:events]
    failure = events.find { |e| e.type == "turn.failed" }
    assert failure, "turn.failed must be served from the durable log"
    assert_match(/provider exploded/, failure.payload["error"])
    refute_empty failure.payload["turnId"]

    assert_includes @manager.host.events(sid).map(&:type), "turn.failed"
  end

  def test_close_session_closes_the_durable_record
    sid = @manager.create_session(model: "gpt-4o")
    adapter = @manager.get(sid)
    adapter.session.stubs(:delete)

    assert @manager.close_session(sid)
    assert_nil @manager.get(sid)

    record = @manager.host.session(sid)
    assert_equal :closed, record.status

    last = @manager.host.events(sid).last
    assert_equal "session.ended", last.type
    assert_equal 2, last.seq
  end

  # ── Standalone adapter ─────────────────────────────────────────────────

  def test_agent_adapter_defaults_to_its_own_host
    adapter = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    sid = adapter.start_session

    assert_equal :active, adapter.host.session(sid).status

    adapter.close!
    assert_equal :closed, adapter.host.session(sid).status
  end

  private

  def rpc(id, method, params)
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  def output_lines(io)
    io.string.lines.map { |line| JSON.parse(line.strip) }
  end
end
