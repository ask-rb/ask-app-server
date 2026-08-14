# frozen_string_literal: true

require_relative "test_helper"

class IntegrationTest < Minitest::Test
  include AppServerTestHelpers

  # Test that all components work together:
  #   SessionManager → AgentAdapter → EventTranslator → Server protocol
  def test_full_session_lifecycle
    manager = Ask::AppServer::SessionManager.new

    # 1. Create a session
    session_id = manager.create_session(
      workspace_path: "/tmp",
      model: "gpt-4o",
      tools: ["bash", "read"]
    )
    assert session_id

    adapter = manager.get(session_id)
    assert adapter
    assert_equal session_id, adapter.session_id

    # 2. Subscribe
    result = manager.subscribe(session_id, delivery_kind: "replay")
    assert result[:subscription][:sessionId]

    # 3. Verify subscribed
    assert manager.subscribed?(session_id)

    # 4. Read workspace state
    state = manager.read_workspace_state(session_id)
    assert state[:settings]
    assert state.dig(:settings, :model, :current, :modelId)

    # 5. List sessions
    sessions = manager.list_sessions
    assert sessions.any? { |s| s[:sessionId] == session_id }

    # 6. Send message
    sent = manager.send_message(session_id, "Hello!")
    assert sent[:accepted]

    # 7. Check events: the session.created event is always present
    events = manager.get_events(session_id, after_seq: 0)
    assert events
    assert_equal session_id, events[:sessionId]
    assert_equal "session.created", events[:events][0].type

    # 8. Destroy session
    assert manager.destroy_session(session_id)
    assert_nil manager.get(session_id)
  end

  def test_multiple_sessions_independent
    manager = Ask::AppServer::SessionManager.new

    sid1 = manager.create_session(workspace_path: "/tmp/a")
    sid2 = manager.create_session(workspace_path: "/tmp/b")

    refute_equal sid1, sid2

    adapter1 = manager.get(sid1)
    adapter2 = manager.get(sid2)

    assert adapter1
    assert adapter2
    refute_equal adapter1.object_id, adapter2.object_id
  end

  def test_session_store_shared_with_manager
    manager = Ask::AppServer::SessionManager.new
    store = manager.store

    sid = manager.create_session(workspace_path: "/tmp")
    assert_equal store.get(sid), manager.get(sid)
  end

  def test_event_translator_attached_to_session
    manager = Ask::AppServer::SessionManager.new
    sid = manager.create_session(workspace_path: "/tmp")
    adapter = manager.get(sid)

    assert adapter.translator
    assert_equal "session.created", adapter.translator.pending_events.last.type
  end

  def test_server_and_manager_integration
    manager = Ask::AppServer::SessionManager.new
    server = Ask::AppServer::Server.new(session_manager: manager)

    assert server.respond_to?(:start)
    assert server.respond_to?(:stop)

    # The server's session manager is ours
    assert_equal manager, server.instance_variable_get(:@session_manager)
  end

  def test_cli_binary_exists
    bin_path = File.expand_path("../../bin/ask-app-server", __FILE__)
    assert File.exist?(bin_path), "CLI binary should exist"
    assert File.executable?(bin_path), "CLI binary should be executable"
  end

  # The daemon mode's whole point: the host serves the socket alone,
  # and its lifetime does NOT depend on stdin. A supervisor's EOF must
  # not take the host down with it.
  def test_socket_only_host_survives_stdin_eof
    require "open3"
    bin_path = File.expand_path("../../bin/ask-app-server", __FILE__)
    stdin_r = stdin_w = wait = nil

    with_tempdir do |dir|
      socket = File.join(dir, "host.sock")
      # stdin is a pipe we close immediately — the stdio transport
      # would see EOF and shut down; socket-only must ignore it.
      stdin_r, stdin_w = IO.pipe
      stdin_r.close
      _out, _err, wait = Open3.popen2e(bin_path, "--socket", socket, "--socket-only", in: stdin_r)
      stdin_w.close

      # Give the host a moment to bind, then speak the protocol.
      deadline = Time.now + 5
      client = nil
      begin
        sleep 0.1
        client = UNIXSocket.new(socket)
      rescue Errno::ENOENT
        retry if Time.now < deadline
        flunk "host did not bind the socket"
      end

      client.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "client" => { "name" => "test", "version" => "1" } } }))
      response = client.gets
      assert response, "host answered over the socket"
      assert_includes response, "capabilities"

      client.close
      assert wait.alive?, "the host outlives its closed stdin"
    ensure
      stdin_r&.close rescue nil
      stdin_w&.close rescue nil
      wait&.kill
    end
  end

  def test_entry_point_loads
    # Just verify no load errors
    require "ask-app-server"
    assert true
  end

  def test_all_lib_files_loaded
    expected_modules = %w[
      Ask::AppServer::VERSION
      Ask::AppServer::EventTranslator
      Ask::AppServer::AgentAdapter
      Ask::AppServer::SessionStore
      Ask::AppServer::SessionManager
      Ask::AppServer::Server
      Ask::AppServer::CLI
    ]

    expected_modules.each do |mod_name|
      parts = mod_name.split("::")
      obj = parts.reduce(Object) { |o, p| o.const_get(p) }
      assert obj, "#{mod_name} should be defined"
    end
  end
end
