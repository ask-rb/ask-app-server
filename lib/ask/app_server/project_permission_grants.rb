# frozen_string_literal: true

require "digest"

module Ask
  module AppServer
    # Persistent tool grants scoped to one canonical workspace identity.
    # Storage is owned by the host and supplied through ask-state-providers.
    class ProjectPermissionGrants
      SNAPSHOT_VERSION = 1

      attr_reader :project_id

      def initialize(state:, project_id:)
        normalized = project_id.to_s.strip
        raise ArgumentError, "project_id must not be blank" if normalized.empty?
        raise ArgumentError, "state must respond to get and set" unless state.respond_to?(:get) && state.respond_to?(:set)

        @state = state
        @project_id = normalized
        @key = "ask-app-server:project-permission-grants:#{Digest::SHA256.hexdigest(normalized)}"
        @mutex = Mutex.new
      end

      def granted?(tool_name)
        name = normalize_tool_name(tool_name)
        @mutex.synchronize { read_tools.include?(name) }
      end

      def grant(tool_name)
        name = normalize_tool_name(tool_name)
        @mutex.synchronize do
          tools = read_tools
          return false if tools.include?(name)

          write_tools(tools + [name])
          true
        end
      end

      def revoke(tool_name)
        name = normalize_tool_name(tool_name)
        @mutex.synchronize do
          tools = read_tools
          return false unless tools.include?(name)

          write_tools(tools - [name])
          true
        end
      end

      def snapshot
        @mutex.synchronize do
          { version: SNAPSHOT_VERSION, granted_tools: read_tools }
        end
      end

      private

      def normalize_tool_name(tool_name)
        name = tool_name.to_s.strip
        raise ArgumentError, "tool_name must not be blank" if name.empty?

        name
      end

      def read_tools
        stored = @state.get(@key)
        return [] if stored.nil?

        version = stored[:version] || stored["version"] if stored.is_a?(Hash)
        tools = stored[:granted_tools] || stored["granted_tools"] if stored.is_a?(Hash)
        unless version == SNAPSHOT_VERSION && tools.is_a?(Array) && tools.all? { |name| name.is_a?(String) && !name.empty? }
          raise Ask::AppServer::Error, "Stored project permission grants are malformed"
        end

        tools.uniq
      end

      def write_tools(tools)
        @state.set(@key, { version: SNAPSHOT_VERSION, granted_tools: tools.sort })
      end
    end
  end
end
