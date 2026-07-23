# frozen_string_literal: true

module Ask
  module AppServer
    # CLI for the ask-app-server command.
    #
    # Usage:
    #   ask-app-server                   # Start in stdio mode (default)
    #   ask-app-server --version         # Show version
    #   ask-app-server --help            # Show help
    #
    # Environment variables:
    #   ASK_APP_SERVER_MODEL   - Model to use (default: gpt-4o)
    #   DEBUG                  - Enable debug logging
    class CLI
      def self.run!(args = ARGV)
        new.run(args)
      end

      def run(args)
        case args.first
        when "--version", "-v"
          puts "ask-app-server v#{Ask::AppServer::VERSION}"
          return
        when "--help", "-h"
          show_help
          return
        end

        model = ENV.fetch("ASK_APP_SERVER_MODEL", "gpt-4o")
        debug_mode = ENV["DEBUG"] == "1"

        $stdout.sync = true
        $stderr.sync = true

        # Build the session manager
        session_manager = SessionManager.new

        # Start the server
        server = Server.new(session_manager: session_manager)

        # Wire the server as the protocol sender for permission requests.
        # Every time a new session is created with a PermissionHandler,
        # the server registers its outgoing request callback.
        session_manager.on_new_permission_handler do |handler|
          server.register_permission_handler(handler)
        end

        # Log startup info
        $stderr.puts "[ask-app-server] Starting v#{Ask::AppServer::VERSION} (model=#{model}, debug=#{debug_mode})" if debug_mode

        begin
          server.start
        rescue Interrupt
          $stderr.puts "\n[ask-app-server] Shutting down..." if debug_mode
          server.stop
        end
      end

      private

      def show_help
        puts <<~HELP
          ask-app-server v#{Ask::AppServer::VERSION}

          JSON-RPC/stdio app-server for ask-rb agents.
          Drop-in compatible with the ZCode/Codex app-server protocol.

          USAGE:
            ask-app-server              Start in stdio mode (reads/writes JSON-RPC over stdin/stdout)

          OPTIONS:
            --version, -v              Show version
            --help, -h                 Show this help message

          ENVIRONMENT:
            ASK_APP_SERVER_MODEL       Model identifier (default: gpt-4o)
            DEBUG                      Set to 1 for debug logging

          PROTOCOL:
            Speaks the standard app-server JSON-RPC protocol over stdio.
            Compatible clients include:
              - ask-coding-providers ZCode adapter
              - ai-sdk-provider-codex-app-server (Vercel AI SDK)
              - zcode-telegram-bot (Python Telegram bot)

          EXAMPLE:
            # Start the server
            ask-app-server

            # From another process, send JSON-RPC requests:
            echo '{"id":1,"method":"session/create","params":{"workspace":{"workspacePath":"."}}}' | ask-app-server
        HELP
      end
    end
  end
end
