# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HerdrReporterTest < Minitest::Test
  # A fake herdr: listens on a unix socket, records every request, and
  # answers each one (the real herdr answers every request too).
  class FakeHerdr
    attr_reader :requests

    def initialize(socket_path)
      @socket_path = socket_path
      @requests = []
      @server = UNIXServer.new(socket_path)
      @thread = Thread.new { accept_loop }
      @queue = Queue.new
    end

    def accept_loop
      loop do
        socket = @server.accept
        @queue << socket
      end
    rescue IOError, Errno::EBADF
      # server closed
    end

    def wait_for_connection(timeout: 2)
      Timeout.timeout(timeout) { @queue.pop }
    rescue Timeout::Error
      nil
    end

    # Drain and answer every request currently buffered by the reporter.
    # The reporter writes synchronously inside event handlers, so once the
    # triggering call returns, its reports are all in the socket buffer.
    def serve_all(timeout: 1.0)
      @socket ||= wait_for_connection(timeout: timeout)
      return unless @socket

      deadline = Time.now + timeout
      idle_polls = 0
      loop do
        ready = IO.select([@socket], nil, nil, 0.02)
        if ready
          line = @socket.gets
          break unless line

          line = line.strip
          unless line.empty?
            msg = JSON.parse(line)
            @requests << msg
            @socket.puts(JSON.generate({ id: msg["id"], result: { ok: true } }))
            @socket.flush
            idle_polls = 0
          end
        else
          idle_polls += 1
          break if idle_polls >= 2
        end
        break if Time.now > deadline
      end
    end

    def requests_for(method)
      @requests.select { |r| r["method"] == method }
    end

    def close
      @socket&.close rescue nil
      @server.close rescue nil
      @thread&.kill
    end
  end

  def setup
    @dir = Dir.mktmpdir("ask-herdr-test")
    @socket_path = File.join(@dir, "herdr.sock")
    @herdr = FakeHerdr.new(@socket_path)
    @session_manager = Ask::AppServer::SessionManager.new
    @reporter = Ask::AppServer::HerdrReporter.new(
      session_manager: @session_manager,
      socket_path: @socket_path,
      pane_id: "pane_1"
    )
    @herdr.serve_all # the initial idle report
  end

  def teardown
    @reporter&.close
    @herdr.close
    FileUtils.rm_rf(@dir) if @dir
  end

  # ── Attach semantics ───────────────────────────────────────────────────

  def test_attach_returns_nil_without_herdr_env
    reporter = Ask::AppServer::HerdrReporter.attach(@session_manager, socket_path: nil, pane_id: "pane_1")
    assert_nil reporter

    reporter = Ask::AppServer::HerdrReporter.attach(@session_manager, socket_path: "/tmp/x.sock", pane_id: nil)
    assert_nil reporter
  end

  def test_attach_returns_reporter_with_env
    reporter = Ask::AppServer::HerdrReporter.attach(@session_manager, socket_path: "/tmp/x.sock", pane_id: "pane_1")
    assert_instance_of Ask::AppServer::HerdrReporter, reporter
  ensure
    reporter&.close
  end

  # ── Reporting ──────────────────────────────────────────────────────────

  def test_initial_idle_report
    report = @herdr.requests_for("pane.report_agent").first
    assert report, "should report the initial idle state"
    assert_equal "idle", report.dig("params", "state")
    assert_equal "pane_1", report.dig("params", "pane_id")
    assert_equal "ask:app-server", report.dig("params", "source")
    assert_equal "ask", report.dig("params", "agent")
  end

  def test_session_created_reports_session_and_metadata
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")

    @herdr.serve_all # session.created event batch

    session_report = @herdr.requests_for("pane.report_agent_session").first
    assert session_report, "should report the agent session"
    assert_equal session_id, session_report.dig("params", "agent_session_id")

    metadata = @herdr.requests_for("pane.report_metadata").first
    assert metadata, "should report metadata"
    assert_equal "1", metadata.dig("params", "tokens", "sessions")
    assert metadata.dig("params", "tokens", "model")
  end

  def test_approval_required_reports_blocked
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")
    @herdr.serve_all

    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash", args: { "command" => "ls" })
    @herdr.serve_all

    report = @herdr.requests_for("pane.report_agent").last
    assert_equal "blocked", report.dig("params", "state")
    assert_equal "awaiting approval", report.dig("params", "message")
  end

  def test_turn_started_reports_working
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "off")
    @herdr.serve_all

    adapter = @session_manager.get(session_id)
    adapter.stubs(:running).returns(true)
    adapter.translator.translate(Ask::Agent::Events::TurnStart.new)
    @herdr.serve_all

    report = @herdr.requests_for("pane.report_agent").last
    assert_equal "working", report.dig("params", "state")
  end

  def test_state_transitions_idle_to_blocked_to_idle
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")
    @herdr.serve_all

    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")
    @herdr.serve_all

    # Rejecting resolves through the session (tool result + follow-up
    # turn); stub run so no LLM call happens.
    @session_manager.get(session_id).session.stubs(:run).returns("")
    queue.reject_all
    @herdr.serve_all

    states = @herdr.requests_for("pane.report_agent").map { |r| r.dig("params", "state") }
    assert_includes states, "blocked"
    assert_equal "idle", states.last, "rejecting the approval should return the pane to idle"
  end

  def test_unchanged_state_is_not_re_reported
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "off")
    @herdr.serve_all
    count_before = @herdr.requests_for("pane.report_agent").size

    # Streaming deltas cannot change the aggregate state.
    adapter = @session_manager.get(session_id)
    adapter.translator.translate(Ask::Agent::Events::TurnStart.new)
    @herdr.serve_all

    # Still idle (no running turn): nothing new to report.
    assert_equal count_before, @herdr.requests_for("pane.report_agent").size
  end

  def test_seq_is_monotonic
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")
    @herdr.serve_all
    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")
    @herdr.serve_all

    seqs = @herdr.requests.map { |r| r.dig("params", "seq") }.compact
    assert_equal seqs.sort, seqs, "seq must be monotonic"
    assert_equal seqs.uniq.size, seqs.size, "seq must be unique"
  end

  def test_missing_herdr_socket_does_not_crash
    reporter = Ask::AppServer::HerdrReporter.new(
      session_manager: @session_manager,
      socket_path: File.join(@dir, "nonexistent.sock"),
      pane_id: "pane_1"
    )

    # Reporting to a missing socket must be a silent no-op.
    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")
    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")
    assert true
  ensure
    reporter&.close
  end

  def test_close_stops_reporting
    @reporter.close
    before = @herdr.requests.size

    session_id = @session_manager.create_session(workspace_path: "/tmp", mode: "on_request")
    queue = @session_manager.get(session_id).session.approval_queue
    queue.submit(tool_call_id: "call-1", tool_name: "bash")

    assert_equal before, @herdr.requests.size, "no reports after close"
  end
end
