# frozen_string_literal: true

require_relative "test_helper"

# Durable state/provider injection: SessionManager and AgentAdapter can
# build a ProviderStore-backed Ask::Session::Host from any
# ask-state-providers adapter, without forcing a concrete backend or
# changing the default in-memory Host.
class SessionDurableConfigTest < Minitest::Test
  def test_session_manager_state_adapter_builds_provider_store_host
    manager = Ask::AppServer::SessionManager.new(state_adapter: Ask::State::Memory.new)

    assert_instance_of Ask::Session::ProviderStore,
                       manager.host.instance_variable_get(:@store)
  end

  def test_agent_adapter_state_adapter_builds_provider_store_host
    adapter = Ask::AppServer::AgentAdapter.new(
      model: "gpt-4o",
      state_adapter: Ask::State::Memory.new
    )

    assert_instance_of Ask::Session::ProviderStore,
                       adapter.host.instance_variable_get(:@store)
  end

  def test_explicit_host_wins_over_state_adapter
    host = Ask::Session::Host.new
    manager = Ask::AppServer::SessionManager.new(
      host: host,
      state_adapter: Ask::State::Memory.new
    )

    assert_same host, manager.host
  end

  def test_defaults_stay_in_memory
    manager = Ask::AppServer::SessionManager.new
    assert_instance_of Ask::Session::Store,
                       manager.host.instance_variable_get(:@store)

    adapter = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    assert_instance_of Ask::Session::Store,
                       adapter.host.instance_variable_get(:@store)
  end

  def test_agent_adapter_state_adapter_persists_to_the_provider
    state = Ask::State::Memory.new
    adapter = Ask::AppServer::AgentAdapter.new(model: "gpt-4o", state_adapter: state)
    sid = adapter.start_session

    assert state.get("ask.session:record:#{sid}"), "record persisted via ProviderStore"
    adapter.close!
    assert state.get("ask.session:record:#{sid}"), "closed record still persisted"
  end
end

require "tmpdir"
require "fileutils"

# Restart resume over a durable ProviderStore/SQLite backend: instance 1
# creates and runs a session against the provider; instance 2 (a fresh
# manager/server over the same database) resumes it from the Host —
# restoring the snapshot conversation, replaying the durable log, and
# continuing with new runs. Model/tool configuration is not serialized;
# instance 2 uses the configured manager defaults.
class SessionRestartResumeTest < Minitest::Test
  include AppServerTestHelpers

  SQLITE_AVAILABLE =
    begin
      require "sqlite3"
      require "ask-state-providers"
      true
    rescue LoadError
      false
    end

  def setup
    unless SQLITE_AVAILABLE && defined?(Ask::State::Providers::SQLite)
      skip "sqlite3 / ask-state-providers not available"
    end

    @dir = Dir.mktmpdir("ask-app-server-restart")
    @db_path = File.join(@dir, "sessions.db")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # ── Manager restart ────────────────────────────────────────────────────

  def test_manager_restart_resume_restores_replays_and_continues
    manager1, state1 = build_manager
    sid = manager1.create_session(model: "gpt-4o")
    adapter1 = manager1.get(sid)

    seed_conversation(adapter1.session, user: "persist me", assistant: "persisted")
    drive_turn(manager1, adapter1, delta: "Hi")

    # The successful run left a durable snapshot for restart resume.
    assert manager1.host.events(sid).any? { |e| e.type == "agent.snapshot" },
           "run wrote an agent.snapshot to the durable Host"
    state1.close

    manager2, state2 = build_manager
    refute manager2.get(sid), "live registry starts empty after restart"

    adapter2 = manager2.resume_session(sid)
    assert_equal sid, adapter2.session_id

    # Snapshot restored: the conversation is back under a fresh session.
    contents = adapter2.session.chat.messages.map { |m| [m.role, m.content] }
    assert_includes contents, [:user, "persist me"]
    assert_includes contents, [:assistant, "persisted"]

    # createdAt comes from the durable record, not the resume time.
    assert_in_delta adapter1.created_at.to_i, adapter2.created_at.to_i, 2

    # Replay reads the durable Host: protocol events survive, the
    # agent.snapshot stays off the wire.
    events = manager2.get_events(sid, after_seq: 0)[:events]
    assert_equal %w[session.created model.streaming], events.map(&:type)
    assert_equal [1, 2], events.map(&:seq)
    assert_equal({ "delta" => "Hi" }, events[1].payload)

    # Continue: new runs keep appending to the same durable log.
    drive_turn(manager2, adapter2, delta: "More")
    after = manager2.get_events(sid, after_seq: events.last.seq)[:events]
    assert_equal ["model.streaming"], after.map(&:type)
    assert_equal({ "delta" => "More" }, after[0].payload)

    # Exactly one snapshot per successful run; the restored
    # SessionAdapter's own event handler did not double-write the
    # agent vocabulary into the protocol log.
    host_types = manager2.host.events(sid).map(&:type)
    assert_equal 2, host_types.count("agent.snapshot")
    refute_includes host_types, "message.added"

    # The translator remains the sole turn.started writer: one event,
    # in the protocol payload shape (not SessionAdapter's turn_id).
    adapter2.session.emit(Ask::Agent::Events::TurnStart.new)
    turns = manager2.host.events(sid).select { |e| e.type == "turn.started" }
    assert_equal 1, turns.size, "exactly one durable turn.started (translator only)"
    assert turns.first.payload.key?(:turnId), "protocol payload shape, not agent vocabulary"

    state2.close
  end

  def test_manager_durable_resume_without_snapshot_attaches_fresh_session
    manager1, state1 = build_manager
    sid = manager1.create_session(model: "gpt-4o")
    state1.close

    manager2, state2 = build_manager
    adapter2 = manager2.resume_session(sid)

    assert_equal sid, adapter2.session_id
    roles = adapter2.session.chat.messages.map(&:role)
    refute_includes roles, :user, "no snapshot → no conversation restore"

    events = manager2.get_events(sid, after_seq: 0)[:events]
    assert_equal ["session.created"], events.map(&:type)

    # The fresh session can continue against the same durable record.
    drive_turn(manager2, adapter2, delta: "After")
    after = manager2.get_events(sid, after_seq: 1)[:events]
    assert_equal ["model.streaming"], after.map(&:type)
    assert_equal({ "delta" => "After" }, after[0].payload)

    state2.close
  end

  def test_manager_resume_prefers_the_live_adapter
    manager, state = build_manager
    sid = manager.create_session(model: "gpt-4o")

    assert_same manager.get(sid), manager.resume_session(sid)
    state.close
  end

  def test_manager_durable_resume_unknown_session_raises
    manager, state = build_manager

    assert_raises(Ask::AppServer::SessionNotFound) { manager.resume_session("missing") }
    state.close
  end

  def test_manager_durable_resume_refuses_closed_session
    manager1, state1 = build_manager
    sid = manager1.create_session(model: "gpt-4o")
    assert manager1.close_session(sid)
    state1.close

    manager2, state2 = build_manager
    assert_raises(Ask::AppServer::SessionNotFound) { manager2.resume_session(sid) }
    state2.close
  end

  # Workspace context across a real restart: project grants are stored
  # under the hashed workspace identity and only come back when the
  # resume caller proves the context with a path that canonicalizes to
  # that identity. Absent/mismatched context resumes without project
  # scope and without pinning tools to any workspace.
  def test_manager_restart_resume_workspace_context_fails_closed_without_proof
    manager1, state1 = build_manager
    sid = manager1.create_session(model: "gpt-4o", workspace_path: @dir)
    manager1.get(sid).session.approval_policy.project_grants.grant("bash")
    manager1.host.append(sid, type: "agent.snapshot", payload: { messages: [], turn_count: 0 })
    state1.close

    # Absent context: fail closed — stored grants stay unattached.
    manager2, state2 = build_manager
    unverified = manager2.resume_session(sid)
    assert_nil unverified.session.approval_policy.project_grants
    assert_equal %w[once session], unverified.allowed_approval_scopes
    assert_nil bash_workdir(unverified)

    # Mismatched context: another directory never unlocks this
    # project's grants either.
    manager3, state3 = build_manager
    mismatched = manager3.resume_session(sid, workspace_path: File.join(@dir, "other-project"))
    assert_nil mismatched.session.approval_policy.project_grants
    assert_equal %w[once session], mismatched.allowed_approval_scopes
    assert_nil bash_workdir(mismatched)

    # Matching context (different spelling of the same directory):
    # grants restore and tools pin to the canonical workspace.
    manager4, state4 = build_manager
    verified = manager4.resume_session(sid, workspace_path: File.join(@dir, "."))
    assert verified.session.approval_policy.project_grants.granted?("bash")
    assert_equal %w[once session project], verified.allowed_approval_scopes
    assert_equal File.realpath(@dir), bash_workdir(verified)

    # The persisted identity stays a hash — no raw path leaked into
    # session metadata through the SQLite JSON round-trip.
    metadata = manager4.store.metadata(sid)
    assert metadata[:workspaceId].start_with?("workspace:")
    refute_includes metadata.values.map(&:to_s).join(" "), @dir
    refute_includes metadata.values.map(&:to_s).join(" "), File.realpath(@dir)

    [state2, state3, state4].each(&:close)
  end

  # ── Server restart ─────────────────────────────────────────────────────

  def test_server_restart_resume_replay_and_continue
    manager1, state1 = build_manager
    server1 = Ask::AppServer::Server.new(session_manager: manager1)
    out1 = StringIO.new
    out1.sync = true
    conn1 = server1.add_connection(
      Ask::AppServer::Connection.new(StringIO.new(""), out1)
    )

    server1.dispatch(rpc(1, "session/create", { "model" => "gpt-4o" }), conn1)
    sid = output_lines(out1)[0].dig("result", "session", "sessionId")
    assert sid

    adapter1 = manager1.get(sid)
    seed_conversation(adapter1.session, user: "persist me", assistant: "persisted")
    drive_turn(manager1, adapter1, delta: "Hi")
    state1.close

    manager2, state2 = build_manager
    server2 = Ask::AppServer::Server.new(session_manager: manager2)
    out2 = StringIO.new
    out2.sync = true
    conn2 = server2.add_connection(
      Ask::AppServer::Connection.new(StringIO.new(""), out2)
    )

    # Resume across the restart.
    server2.dispatch(rpc(1, "session/resume", { "sessionId" => sid }), conn2)
    resume = output_lines(out2)[0]
    assert_equal sid, resume.dig("result", "sessionId")
    assert resume.dig("result", "idle")
    assert resume.dig("result", "createdAt")

    # Replay the durable log over the protocol.
    server2.dispatch(
      rpc(2, "session/events", { "sessionId" => sid, "afterSeq" => 0 }), conn2
    )
    events = output_lines(out2)[1].dig("result", "events")
    assert_equal %w[session.created model.streaming], events.map { |e| e["type"] }
    assert_equal [1, 2], events.map { |e| e["seq"] }
    assert_equal({ "delta" => "Hi" }, events[1]["payload"])

    # The conversation was restored from the snapshot.
    adapter2 = manager2.get(sid)
    contents = adapter2.session.chat.messages.map { |m| [m.role, m.content] }
    assert_includes contents, [:user, "persist me"]

    # Continue: a new turn appends after the replayed cursor.
    drive_turn(manager2, adapter2, delta: "More", send_via: [server2, conn2], sid: sid)
    server2.dispatch(
      rpc(4, "session/events", { "sessionId" => sid, "afterSeq" => events.last["seq"] }), conn2
    )
    after = output_lines(out2)[3].dig("result", "events")
    assert_equal ["model.streaming"], after.map { |e| e["type"] }
    assert_equal({ "delta" => "More" }, after[0]["payload"])

    state2.close
  end

  private

  def build_manager
    state = Ask::State::Providers::SQLite.new(path: @db_path)
    [Ask::AppServer::SessionManager.new(state_adapter: state), state]
  end

  # Seed a conversation the way a completed run leaves it in the chat
  # transcript (the snapshot source).
  def seed_conversation(session, user:, assistant:)
    session.chat.add_message(role: :user, content: user)
    session.chat.add_message(role: :assistant, content: assistant)
  end

  # Drive one turn without a live LLM: stub the run, push a canonical
  # event through the session's event pipeline (the same path a real run
  # uses), then send and wait for the run thread — which appends the
  # end-of-run snapshot.
  def drive_turn(manager, adapter, delta:, send_via: nil, sid: nil)
    adapter.session.stubs(:run).returns("done")
    adapter.session.stubs(:queued_steers).returns(0)
    adapter.session.stubs(:turn_id).returns("turn-1")
    adapter.session.emit(Ask::Agent::Events::TextDelta.new(content: delta))

    if send_via
      server, connection = send_via
      server.dispatch(
        rpc(99, "session/send", { "sessionId" => sid, "content" => "prompt" }),
        connection
      )
    else
      result = manager.send_message(adapter.session_id, "prompt")
      assert result[:accepted]
    end
    assert adapter.wait_for_turn(timeout: 2), "turn should complete"
  end

  def rpc(id, method, params)
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  # The pinned workdir of the session's bash tool (nil when the resume
  # did not verify workspace context).
  def bash_workdir(adapter)
    bash = adapter.session.tools.find { |tool| tool.is_a?(Ask::Tools::Bash) }
    bash&.default_workdir
  end

  def output_lines(io)
    io.string.lines.map { |line| JSON.parse(line.strip) }
  end
end
