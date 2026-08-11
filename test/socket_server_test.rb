# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class SocketServerTest < Minitest::Test
  # A raw NDJSON client over the unix socket: writes requests, matches
  # responses by id, and buffers any notifications that arrive.
  class Client
    attr_reader :notifications

    def initialize(socket_path)
      @socket = connect_with_retry(socket_path)
      @buffer = +""
      @next_id = 1
      @notifications = []
    end

    def request(method, params = {})
      id = @next_id
      @next_id += 1
      @socket.puts(JSON.generate({ id: id, method: method, params: params }))
      deadline = Time.now + 3
      loop do
        read_available
        response = @notifications.find { |m| m["id"] == id }
        next unless response

        @notifications.delete(response)
        return response
      end
    end

    # Read whatever the server has written; returns once the socket
    # settles (two consecutive empty polls) or the timeout expires.
    def read_available(timeout: 1.0)
      deadline = Time.now + timeout
      idle_polls = 0
      loop do
        ready = IO.select([@socket], nil, nil, 0.02)
        if ready
          line = @socket.gets
          break unless line
          line = line.strip
          @notifications << JSON.parse(line) unless line.empty?
          idle_polls = 0
        else
          idle_polls += 1
          break if idle_polls >= 2
        end
        break if Time.now > deadline
      end
      @notifications
    end

    def close
      @socket.close rescue nil
    end

    private

    def connect_with_retry(socket_path)
      deadline = Time.now + 3
      loop do
        return UNIXSocket.new(socket_path)
      rescue Errno::ECONNREFUSED, Errno::ENOENT
        raise "socket #{socket_path} not accepting connections" if Time.now > deadline
        sleep 0.02
      end
    end
  end

  def setup
    @dir = Dir.mktmpdir("ask-socket-test")
    @socket_path = File.join(@dir, "app-server.sock")
    @session_manager = Ask::AppServer::SessionManager.new
    @server = Ask::AppServer::SocketServer.new(
      session_manager: @session_manager,
      socket_path: @socket_path
    )
    @server.start
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@dir) if @dir
  end

  # ── Handshake over the socket ──────────────────────────────────────────

  def test_client_handshake_over_socket
    client = Client.new(@socket_path)

    response = client.request("initialize", { client: { name: "test", version: "1" } })
    assert_equal "ask-app-server", response.dig("result", "server", "name")
    assert_equal Ask::SessionProtocol::PROTOCOL_VERSION, response.dig("result", "protocolVersion")
  ensure
    client&.close
  end

  def test_full_session_lifecycle_over_socket
    client = Client.new(@socket_path)

    created = client.request("session/create", { mode: "on_request" })
    session_id = created.dig("result", "session", "sessionId")
    assert session_id

    subscribed = client.request("session/subscribe", { sessionId: session_id })
    assert_equal session_id, subscribed.dig("result", "subscription", "sessionId")

    sent = client.request("session/send", { sessionId: session_id, content: "Hello" })
    assert_equal "steered", sent.dig("result", "status")

    closed = client.request("session/close", { sessionId: session_id })
    assert closed.dig("result", "closed")
  ensure
    client&.close
  end

  # ── Multi-client event fan-out ─────────────────────────────────────────

  def test_two_clients_receive_the_same_session_events
    client_a = Client.new(@socket_path)
    client_b = Client.new(@socket_path)

    created = client_a.request("session/create", { mode: "on_request" })
    session_id = created.dig("result", "session", "sessionId")

    client_a.request("session/subscribe", { sessionId: session_id })
    client_b.request("session/subscribe", { sessionId: session_id })

    # Deterministic event source: a real approval queue submit flows
    # through EmittingApprovalQueue → translator → session log.
    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" })

    @server.protocol.push_pending

    types_a = client_a.read_available.map { |m| m.dig("params", "event", "type") }
    types_b = client_b.read_available.map { |m| m.dig("params", "event", "type") }

    assert_includes types_a, "session.created"
    assert_includes types_a, "approval.required"
    assert_equal types_a, types_b, "both clients must see the same events"
  ensure
    client_a&.close
    client_b&.close
  end

  def test_delivery_cursors_are_per_connection
    client_a = Client.new(@socket_path)
    client_b = Client.new(@socket_path)

    created = client_a.request("session/create", { mode: "on_request" })
    session_id = created.dig("result", "session", "sessionId")

    # A subscribes after seq 1 (skips session.created); B replays from 0.
    client_a.request("session/subscribe", { sessionId: session_id, afterSeq: 1 })
    client_b.request("session/subscribe", { sessionId: session_id, afterSeq: 0 })

    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    @server.protocol.push_pending

    a_events = client_a.read_available.map { |m| m.dig("params", "event") }
    b_events = client_b.read_available.map { |m| m.dig("params", "event") }

    refute a_events.any? { |e| e["type"] == "session.created" },
           "client A subscribed after session.created and must not receive it"
    assert b_events.any? { |e| e["type"] == "session.created" },
           "client B subscribed from 0 and should receive the replay"
    assert a_events.any? { |e| e["type"] == "approval.required" }
  ensure
    client_a&.close
    client_b&.close
  end

  def test_client_resolves_an_interaction_over_the_socket
    client = Client.new(@socket_path)

    created = client.request("session/create", { mode: "on_request" })
    session_id = created.dig("result", "session", "sessionId")

    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    listed = client.request("interaction/list", { sessionId: session_id })
    interactions = listed.dig("result", "interactions")
    assert_equal 1, interactions.size
    assert_equal "act_1", interactions[0]["id"]

    # Resolving a real action would execute the tool and start a follow-up
    # LLM turn; stub the adapter to assert the protocol routing only.
    @session_manager.get(session_id).stubs(:approve_interaction).with("act_1").returns(true)
    approved = client.request("interaction/approve", { sessionId: session_id, interactionId: "act_1" })
    assert approved.dig("result", "approved")
  ensure
    client&.close
  end

  # ── Disconnect handling ────────────────────────────────────────────────

  def test_disconnect_removes_connection
    client = Client.new(@socket_path)
    client.request("ping")

    assert_equal 1, @server.protocol.connections.size

    client.close
    deadline = Time.now + 2
    sleep 0.05 while @server.protocol.connections.size.positive? && Time.now < deadline

    assert_empty @server.protocol.connections
    @server.protocol.push_pending # must not raise
  end

  def test_stop_removes_socket_file
    @server.stop
    refute File.exist?(@socket_path), "socket file should be removed on stop"
    assert_raises(Errno::ENOENT) { UNIXSocket.new(@socket_path) }
  end

  def test_start_replaces_stale_socket_file
    @server.stop
    File.write(@socket_path, "stale")

    server2 = Ask::AppServer::SocketServer.new(
      session_manager: Ask::AppServer::SessionManager.new,
      socket_path: @socket_path
    )
    server2.start
    client = Client.new(@socket_path)
    response = client.request("ping")
    assert_equal "ok", response.dig("result", "status")
  ensure
    client&.close
    server2&.stop
  end
end
