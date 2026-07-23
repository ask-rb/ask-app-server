# frozen_string_literal: true

require "fileutils"

module Ask
  module AppServer
    # CLI for the ask-app-server command.
    #
    # Usage:
    #   ask-app-server                   # Start in stdio mode (default)
    #   ask-app-server --version         # Show version
    #   ask-app-server --help            # Show help
    #   ask-app-server --config PATH     # Use specific config file
    #
    # Environment variables:
    #   ASK_APP_SERVER_CONFIG   - Path to config file (default: auto-detect)
    #   ASK_APP_SERVER_MODEL    - Model to use (overrides config file)
    #   ASK_APP_SERVER_PERMISSIONS - Permission mode (overrides config file)
    #   DEBUG                   - Enable debug logging (1/0)
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

        # Parse --config from args
        config_path = nil
        remaining_args = []
        args.each_with_index do |arg, i|
          if arg == "--config" && i + 1 < args.length
            config_path = args[i + 1]
          elsif !arg.start_with?("--config")
            remaining_args << arg
          end
        end

        # Load configuration
        config = Config.new(config_path: config_path)

        # Register custom models from config into the model catalog
        config.register_models!

        $stdout.sync = true
        $stderr.sync = true

        if config.debug?
          $stderr.puts "[ask-app-server] Starting v#{Ask::AppServer::VERSION}"
          $stderr.puts "[ask-app-server] Config: #{JSON.pretty_generate(config.to_h)}"
        end

        # Build the session manager with config values
        store = build_state_store(config)
        session_manager = SessionManager.new(
          store: store,
          permission_mode: config.permission_mode,
          blocked_tools: config.blocked_tools,
          permission_timeout: config.permission_timeout
        )

        # Start the server
        server = Server.new(session_manager: session_manager)

        # Wire the server as the protocol sender for permission requests.
        # Every time a new session is created with a PermissionHandler,
        # the server registers its outgoing request callback.
        session_manager.on_new_permission_handler do |handler|
          server.register_permission_handler(handler)
        end

        begin
          server.start
        rescue Interrupt
          $stderr.puts "\n[ask-app-server] Shutting down..." if config.debug?
          server.stop
        end
      end

      private

      def build_state_store(config)
        # Default path: ~/.ask-app-server/state.db
        sqlite_path = config.state_sqlite_path || File.expand_path("~/.ask-app-server/state.db")

        begin
          require "sqlite3"
          require "ask/state/providers/sqlite"
        rescue LoadError
          $stderr.puts "[ask-app-server] sqlite3 gem not available, using in-memory state store." if config.debug?
          return nil
        end

        dir = File.dirname(File.expand_path(sqlite_path))
        FileUtils.mkdir_p(dir) unless File.directory?(dir)

        state = Ask::State::Providers::SQLite.new(path: sqlite_path)
        $stderr.puts "[ask-app-server] State store: #{sqlite_path}" if config.debug?
        Ask::AppServer::SessionStore.new(state: state)
      rescue => e
        $stderr.puts "[ask-app-server] Warning: Could not initialize SQLite state: #{e.message}"
        $stderr.puts "[ask-app-server] Falling back to in-memory state store."
        nil
      end

      def show_help
        puts <<~HELP
          ask-app-server v#{Ask::AppServer::VERSION}

          JSON-RPC/stdio app-server for ask-rb agents.
          Drop-in compatible with the ZCode/Codex app-server protocol.

          USAGE:
            ask-app-server                  Start in stdio mode

          OPTIONS:
            --version, -v                  Show version
            --help, -h                     Show this help message
            --config PATH                  Config file path (default: auto-detect)

          CONFIG FILE (JSON):
            Search order:
              1. ASK_APP_SERVER_CONFIG env
              2. ./.ask-app-server.json
              3. ~/.ask-app-server/config.json

            Example ~/.ask-app-server/config.json:
              {
                "model": "claude-sonnet-4",
                "tools": ["bash", "read", "write", "edit", "glob", "grep"],
                "permissions": {
                  "mode": "on_request",
                  "blocked_tools": ["write", "edit", "bash", "destroy"],
                  "timeout": 300
                },
                "system_prompt": "You are a coding assistant...",
                "session": { "timeout": 600 }
              }

          ENVIRONMENT:
            ASK_APP_SERVER_CONFIG        Config file path
            ASK_APP_SERVER_MODEL         Model identifier (overrides config)
            ASK_APP_SERVER_PERMISSIONS   Permission mode (overrides config)
            DEBUG                        Set to 1 for debug logging

          PROTOCOL:
            Speaks the standard app-server JSON-RPC protocol over stdio.
            Compatible clients:
              - ask-coding-providers ZCode adapter
              - ai-sdk-provider-codex-app-server (Vercel AI SDK)
              - zcode-telegram-bot (Python Telegram bot)

          EXAMPLE:
            # Start with defaults
            ask-app-server

            # Start with a specific config
            ask-app-server --config /path/to/config.json

            # Send a ping from another shell:
            echo '{"id":1,"method":"ping"}' | ask-app-server
        HELP
      end
    end
  end
end
