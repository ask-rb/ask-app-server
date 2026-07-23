# frozen_string_literal: true

require "json"

module Ask
  module AppServer
    # Configuration loader for ask-app-server.
    #
    # Reads from a JSON config file, then merges environment variable overrides.
    # Config file search order (first found wins):
    #   1. ASK_APP_SERVER_CONFIG env var (explicit path)
    #   2. ./.ask-app-server.json (project-local)
    #   3. ~/.ask-app-server/config.json (user-global)
    #
    # Environment variable overrides:
    #   ASK_APP_SERVER_MODEL       — model identifier
    #   ASK_APP_SERVER_PERMISSIONS — permission mode (on_request, never)
    #   DEBUG                      — debug logging
    #
    # Example config file (~/.ask-app-server/config.json):
    #   {
    #     "model": "claude-sonnet-4",
    #     "tools": ["bash", "read", "write", "edit", "glob", "grep"],
    #     "permissions": {
    #       "mode": "on_request",
    #       "blocked_tools": ["write", "edit", "bash", "destroy"],
    #       "timeout": 300
    #     },
    #     "system_prompt": "You are a helpful AI coding assistant.",
    #     "session": {
    #       "timeout": 600
    #     }
    #   }
    class Config
      DEFAULTS = {
        model: "gpt-4o",
        tools: %w[bash read write edit glob grep].freeze,
        permissions: {
          mode: :on_request,
          blocked_tools: %w[write edit bash destroy].freeze,
          timeout: 300
        }.freeze,
        system_prompt: nil,
        session: {
          timeout: 600
        }.freeze
      }.freeze

      CONFIG_FILE_PATHS = [
        -> { ENV["ASK_APP_SERVER_CONFIG"] },
        -> { File.expand_path(".ask-app-server.json") },
        -> { File.expand_path("~/.ask-app-server/config.json") }
      ].freeze

      attr_reader :source_path

      def initialize(config_path: nil)
        @source_path = nil
        @data = load_config(config_path)
      end

      # Resolved model identifier.
      def model
        ENV.fetch("ASK_APP_SERVER_MODEL", @data[:model])
      end

      # List of tool names to load.
      def tools
        @data[:tools] || DEFAULTS[:tools]
      end

      # Permission mode symbol (:on_request, :never).
      def permission_mode
        env_mode = ENV["ASK_APP_SERVER_PERMISSIONS"]
        return env_mode.to_sym if env_mode

        raw = @data.dig(:permissions, :mode)
        raw ? raw.to_sym : DEFAULTS.dig(:permissions, :mode)
      end

      # List of tool names that require permission.
      def blocked_tools
        @data.dig(:permissions, :blocked_tools)&.map(&:to_s) || DEFAULTS.dig(:permissions, :blocked_tools)
      end

      # Permission request timeout in seconds.
      def permission_timeout
        @data.dig(:permissions, :timeout) || DEFAULTS.dig(:permissions, :timeout)
      end

      # System prompt for the agent.
      def system_prompt
        @data[:system_prompt]
      end

      # Session timeout in seconds.
      def session_timeout
        @data.dig(:session, :timeout) || DEFAULTS.dig(:session, :timeout)
      end

      # Whether debug logging is enabled.
      def debug?
        ENV["DEBUG"] == "1"
      end

      # All config as a hash (for display).
      def to_h
        {
          model: model,
          tools: tools,
          permissions: {
            mode: permission_mode,
            blocked_tools: blocked_tools,
            timeout: permission_timeout
          },
          system_prompt: system_prompt,
          session: { timeout: session_timeout },
          source: source_path || "(defaults)"
        }
      end

      private

      def load_config(config_path)
        path = config_path || find_config_file
        return deep_copy(DEFAULTS) unless path && File.exist?(path)

        @source_path = File.expand_path(path)
        raw = JSON.parse(File.read(@source_path))

        # Deep merge with defaults
        merged = deep_merge(deep_copy(DEFAULTS), normalize_keys(raw))
        merged
      rescue JSON::ParserError => e
        warn "[ask-app-server] Warning: Invalid config file #{path}: #{e.message}"
        deep_copy(DEFAULTS)
      end

      def find_config_file
        CONFIG_FILE_PATHS.each do |resolver|
          path = resolver.call
          return path if path && File.exist?(path)
        end
        nil
      end

      # Deep merge b into a (b values win).
      def deep_merge(a, b)
        a.merge(b) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          elsif old_val.is_a?(Array) && new_val.is_a?(Array)
            new_val
          else
            new_val
          end
        end
      end

      # Deep copy a hash (for defaults that are frozen).
      def deep_copy(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_copy(v) }
        when Array then obj.map { |v| deep_copy(v) }
        else obj
        end
      end

      # Convert string keys to symbols recursively.
      def normalize_keys(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = normalize_keys(v) }
        when Array then obj.map { |v| normalize_keys(v) }
        else obj
        end
      end
    end
  end
end
