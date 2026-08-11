# frozen_string_literal: true

require "json"
require "socket"

module Ask
  module AppServer
    # Herdr citizenship: when the host runs inside a herdr pane, herdr
    # injects HERDR_SOCKET_PATH and HERDR_PANE_ID into the pane's
    # environment. This reporter connects to herdr's socket and keeps the
    # sidebar accurate with first-party state — the host KNOWS when a turn
    # is running or an approval is pending, which beats screen scraping:
    #
    #   pane.report_agent       — working | blocked | idle, on change
    #   pane.report_agent_session — the ask session id, for future resume
    #   pane.report_metadata    — model and session count as sidebar tokens
    #
    # The pane state is the aggregate across the host's sessions (a host
    # can serve many clients): blocked if any session awaits an approval,
    # working if any turn is running, idle otherwise. Events that cannot
    # change the aggregate (model.streaming, tool.*, todos) are ignored.
    #
    # Attach once per session manager: HerdrReporter.attach(manager).
    class HerdrReporter
      SOCKET_PATH_ENV = "HERDR_SOCKET_PATH"
      PANE_ID_ENV = "HERDR_PANE_ID"

      # Reports originate from the ask host; herdr uses the pair to dedup
      # and order per-source reports.
      SOURCE = "ask:app-server"
      AGENT = "ask"

      # Events that can change the aggregate pane state.
      STATE_EVENTS = %w[
        turn.started turn.completed turn.failed turn.aborted
        approval.required approval.updated
        plan.proposed plan.approved plan.rejected
        session.created session.ended
      ].freeze

      # @return [HerdrReporter, nil] a live reporter, or nil when herdr
      #   environment variables are absent (not running in a herdr pane)
      def self.attach(session_manager, socket_path: ENV[SOCKET_PATH_ENV], pane_id: ENV[PANE_ID_ENV])
        return nil if socket_path.to_s.empty? || pane_id.to_s.empty?

        new(session_manager: session_manager, socket_path: socket_path, pane_id: pane_id)
      end

      # @param session_manager [SessionManager]
      # @param socket_path [String] herdr's socket (HERDR_SOCKET_PATH)
      # @param pane_id [String] this pane (HERDR_PANE_ID)
      def initialize(session_manager:, socket_path:, pane_id:)
        @session_manager = session_manager
        @socket_path = socket_path
        @pane_id = pane_id
        @seq = 0
        @reported_state = nil
        @socket = nil
        @mutex = Mutex.new
        @enabled = true

        session_manager.on_session_event { |session_id, event| on_event(session_id, event) }
        report_state(compute_state)
      end

      # Stop reporting and drop the herdr connection.
      def close
        @enabled = false
        @mutex.synchronize do
          @socket&.close rescue nil
          @socket = nil
        end
      end

      private

      def on_event(session_id, event)
        return unless @enabled

        case event.type
        when "session.created"
          report_session(session_id)
          report_metadata
        end
        return unless STATE_EVENTS.include?(event.type)

        report_state(compute_state)
      end

      # Aggregate pane state across all sessions: blocked wins over
      # working wins over idle.
      def compute_state
        blocked = false
        working = false
        @session_manager.store.each do |adapter|
          next unless adapter.session_id

          if adapter.pending_interactions.any?
            blocked = true
          elsif adapter.running
            working = true
          end
        end
        blocked ? "blocked" : working ? "working" : "idle"
      end

      def report_state(state)
        return if state == @reported_state

        @reported_state = state
        params = {
          pane_id: @pane_id,
          source: SOURCE,
          agent: AGENT,
          state: state,
          seq: next_seq
        }
        params["message"] = "awaiting approval" if state == "blocked"
        send_request("pane.report_agent", params)
      end

      def report_session(session_id)
        send_request("pane.report_agent_session", {
          pane_id: @pane_id,
          source: SOURCE,
          agent: AGENT,
          agent_session_id: session_id,
          seq: next_seq
        })
      end

      def report_metadata
        send_request("pane.report_metadata", {
          pane_id: @pane_id,
          source: SOURCE,
          agent: AGENT,
          tokens: {
            "model" => current_model,
            "sessions" => @session_manager.store.count.to_s
          },
          seq: next_seq
        })
      end

      def current_model
        model = nil
        @session_manager.store.each do |adapter|
          model = adapter.instance_variable_get(:@model)
          break if model
        end
        model || ENV.fetch("ASK_APP_SERVER_MODEL", "unknown")
      end

      def next_seq
        @mutex.synchronize do
          @seq += 1
        end
      end

      def send_request(method, params)
        socket = ensure_socket
        return unless socket

        socket.puts(JSON.generate({ id: "#{SOURCE}:#{@seq}", method: method, params: params }))
        socket.flush
      rescue Errno::EPIPE, Errno::ECONNREFUSED, IOError
        # herdr went away; the next report reconnects
        @socket = nil
      end

      def ensure_socket
        @mutex.synchronize do
          return @socket if @socket && !@socket.closed?

          begin
            @socket = UNIXSocket.new(@socket_path)
            @drainer = Thread.new { drain_loop(@socket) }
          rescue Errno::ENOENT, Errno::ECONNREFUSED
            @socket = nil
          end
          @socket
        end
      end

      # herdr answers every request; drain responses so the socket never
      # fills. Dies with the socket; the next report reconnects.
      def drain_loop(socket)
        while (line = socket.gets)
          # herdr responses/notifications — nothing to do
        end
      rescue IOError, SystemCallError
        # socket closed
      ensure
        socket.close rescue nil
        @mutex.synchronize { @socket = nil if @socket == socket }
      end
    end
  end
end
