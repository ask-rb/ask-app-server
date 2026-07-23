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
    #   ASK_APP_SERVER_MODEL       — model identifier (e.g., "opencode_go/deepseek-v4-flash")
    #   ASK_APP_SERVER_PERMISSIONS — permission mode (on_request, never)
    #   DEBUG                      — debug logging
    #
    # Example config file (~/.ask-app-server/config.json):
    #   {
    #     "model": "opencode_go/deepseek-v4-flash",
    #     "tools": ["bash", "read", "write", "edit", "glob", "grep"],
    #     "permissions": {
    #       "mode": "on_request",
    #       "blocked_tools": ["write", "edit", "bash", "destroy"],
    #       "timeout": 300
    #     },
    #     "system_prompt": "You are a helpful AI coding assistant.",
    #     "session": { "timeout": 600 },
    #     "custom_models": {
    #       "deepseek-v4-flash": {
    #         "provider": "opencode_go",
    #         "context": 1000000,
    #         "output": 384000
    #       }
    #     }
    #   }
    class Config
      DEFAULTS = {
        model: "opencode_go/deepseek-v4-flash",
        tools: %w[bash read write edit glob grep].freeze,
        permissions: {
          mode: :on_request,
          blocked_tools: %w[write edit bash destroy].freeze,
          timeout: 300
        }.freeze,
        system_prompt: nil,
        session: {
          timeout: 600
        }.freeze,
        custom_models: {}.freeze
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
        @registered = false
      end

      # Resolved model identifier (may include provider prefix).
      def model
        ENV.fetch("ASK_APP_SERVER_MODEL", @data[:model])
      end

      # Parse model into [provider, model_id].
      # Supports "provider/model" format and bare model names.
      def parsed_model
        raw = model
        if raw.include?("/")
          parts = raw.split("/", 2)
          [parts[0], parts[1]]
        else
          [nil, raw]
        end
      end

      # The model ID (without provider prefix).
      def model_id
        parsed_model[1]
      end

      # The provider slug (nil if not specified).
      def model_provider
        parsed_model[0]
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

      # State persistence configuration.
      # Returns nil if no state config is set (use in-memory defaults).
      def state_config
        @data[:state]
      end

      # Path for SQLite state database (if configured).
      def state_sqlite_path
        cfg = state_config
        return nil unless cfg

        cfg[:sqlite_path] || cfg["sqlite_path"] || cfg[:path] || cfg["path"]
      end

      # Whether debug logging is enabled.
      def debug?
        ENV["DEBUG"] == "1"
      end

      # Custom model definitions from config.
      def custom_models
        @data[:custom_models] || {}
      end

      # Register custom models into Ask::ModelCatalog so ask-agent can find them.
      # Safe to call multiple times — models are registered only once.
      def register_models!
        return if @registered
        @registered = true

        custom_models.each do |model_id, cfg|
          provider = cfg[:provider] || cfg["provider"]
          context = cfg[:context] || cfg["context"] || 4096
          output = cfg[:output] || cfg["output"] || 4096

          # Build a ModelInfo-compatible struct and register it
          model_info = OpenStruct.new(
            id: model_id.to_s,
            provider: provider.to_s,
            chat?: true,
            context: context,
            output: output
          )

          # Use the singleton's register if available
          if Ask::ModelCatalog.respond_to?(:instance)
            catalog = Ask::ModelCatalog.instance
            catalog.register(model_info) if catalog.respond_to?(:register)
          end

          if debug?
            warn "[ask-app-server] Registered custom model: #{provider}/#{model_id} (#{context}ctx)"
          end
        end
      end

      # All config as a hash (for display).
      def to_h
        prov, mod = parsed_model
        {
          model: mod,
          provider: prov,
          tools: tools,
          permissions: {
            mode: permission_mode,
            blocked_tools: blocked_tools,
            timeout: permission_timeout
          },
          system_prompt: system_prompt,
          session: { timeout: session_timeout },
          custom_models: custom_models.keys,
          source: source_path || "(defaults)"
        }
      end

      private

      def load_config(config_path)
        path = config_path || find_config_file
        return deep_copy(DEFAULTS) unless path && File.exist?(path)

        @source_path = File.expand_path(path)
        raw = JSON.parse(File.read(@source_path))

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

      def deep_copy(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_copy(v) }
        when Array then obj.map { |v| deep_copy(v) }
        else obj
        end
      end

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
