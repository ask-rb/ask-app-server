# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"

module Ask
  module AppServer
    # Unix-socket transport for the session host: any number of clients can
    # attach to the same sessions (terminal TUI, web console, bots) by
    # connecting to the socket and speaking the canonical session protocol
    # as NDJSON lines.
    #
    # Each accepted connection gets its own reader thread and a Connection
    # with per-session delivery cursors; the shared protocol engine
    # ({Server}) routes responses back to the requesting connection and
    # fans out session/event notifications to every subscribed connection.
    #
    # The socket file is removed on start (stale cleanup) and on stop.
    class SocketServer
      # Default socket path: ASK_APP_SERVER_SOCKET env var or
      # ~/.ask-app-server/app-server.sock
      def self.default_socket_path
        ENV["ASK_APP_SERVER_SOCKET"] ||
          File.expand_path("~/.ask-app-server/app-server.sock")
      end

      attr_reader :socket_path, :protocol

      # @param session_manager [SessionManager, nil] shared session manager
      # @param socket_path [String, nil] unix socket path
      def initialize(session_manager: nil, socket_path: nil)
        @session_manager = session_manager || SessionManager.new
        @protocol = Server.new(session_manager: @session_manager)
        @socket_path = socket_path || self.class.default_socket_path
        @running = false
        @listener = nil
        @acceptor = nil
        @pusher = nil
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Bind the socket and start accepting connections. Returns
      # immediately (accept and push run in background threads).
      def start
        @running = true
        FileUtils.mkdir_p(File.dirname(@socket_path))
        FileUtils.rm_f(@socket_path)  # stale socket from a previous run
        @listener = UNIXServer.new(@socket_path)
        @acceptor = Thread.new { accept_loop }
        @pusher = Thread.new { pusher_loop }
        @logger.debug("Socket server listening on #{@socket_path}")
        self
      end

      # Stop accepting, close all connections, and remove the socket file.
      def stop
        @running = false
        @acceptor&.kill rescue nil
        @pusher&.kill rescue nil
        @protocol.connections.each { |conn| @protocol.remove_connection(conn) }
        @listener&.close rescue nil
        FileUtils.rm_f(@socket_path) rescue nil
      end

      # Whether the server is running.
      def running?
        @running
      end

      private

      def accept_loop
        while @running
          socket = @listener.accept
          connection = @protocol.add_connection(Connection.new(socket, socket))
          reader = Thread.new { reader_loop(connection, socket) }
          reader.name = "ask-socket-client" if reader.respond_to?(:name=)
        end
      rescue IOError, Errno::EBADF, Errno::EINVAL
        # Listener closed during shutdown.
      rescue => e
        @logger.error("Accept error: #{e.message}")
        sleep 0.1
      end

      def reader_loop(connection, socket)
        while @running
          line = connection.read_line
          break unless line
          line = line.strip
          next if line.empty?

          begin
            @protocol.dispatch(JSON.parse(line), connection)
          rescue JSON::ParserError => e
            @protocol.send(:send_error, nil, -32700, "Parse error: #{e.message}", connection)
          rescue => e
            @logger.error("Socket reader error: #{e.message}")
            break
          end
        end
      ensure
        @protocol.remove_connection(connection)
        socket.close rescue nil
      end

      def pusher_loop
        while @running
          @protocol.push_pending
          sleep 0.1  # 100ms poll interval
        end
      end
    end
  end
end
