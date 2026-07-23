# frozen_string_literal: true

require "securerandom"

module Ask
  module AppServer
    # Protocol-aware permission handler that integrates with ask-agent's
    # before_tool_call hook system.
    #
    # When a blocked tool is called, this handler:
    #   1. Sends an `interaction/requestPermission` protocol message to the client
    #   2. Blocks the tool thread until the client responds (or timeout)
    #   3. Returns { action: :proceed } if approved, { action: :block } if denied
    #
    # Usage:
    #   handler = PermissionHandler.new(mode: :on_request)
    #   handler.on_request { |req_id, tool_name, args| send_protocol_message(...) }
    #
    #   # Wire into ask-agent session
    #   session = Ask::Agent::Session.new(hooks: { before_tool: [handler] })
    #
    #   # When the client responds:
    #   handler.handle_response(request_id, "approve")
    class PermissionHandler
      # Default tools that require permission.
      DEFAULT_BLOCKED_TOOLS = %i[write edit bash destroy].freeze

      # Default timeout in seconds.
      DEFAULT_TIMEOUT = 300

      attr_reader :mode

      # @param mode [Symbol] :on_request (ask for dangerous tools) or :never (allow all)
      # @param blocked_tools [Array<Symbol>] list of tool names that require permission
      # @param timeout [Integer] seconds to wait for client response
      def initialize(mode: :on_request, blocked_tools: nil, timeout: DEFAULT_TIMEOUT)
        @mode = mode
        @blocked_tools = (blocked_tools || DEFAULT_BLOCKED_TOOLS).map(&:to_sym)
        @timeout = timeout
        @pending = {}
        @sender = nil
        @mutex = Mutex.new
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Register a callback for sending the protocol message.
      # The callback receives (request_id, tool_name, tool_arguments).
      def on_request(&block)
        @sender = block
      end

      # Hook interface for Ask::Agent::Session's before_tool_call chain.
      # Returns { action: :proceed } or { action: :block, reason: "..." }.
      def before_tool_call(tool_call, _context = {})
        return { action: :proceed } unless @blocked_tools.include?(tool_call.name.to_sym)
        return { action: :proceed } if @mode == :never

        request_approval(tool_call)
      end

      # Called by the server when the client responds to a permission request.
      #
      # @param request_id [String] the ID that was sent in the permission request
      # @param decision [String] "approve" or "deny"
      # @param reason [String, nil] optional reason from the client
      def handle_response(request_id, decision, reason: nil)
        @mutex.synchronize do
          entry = @pending[request_id]
          return false unless entry

          entry[:responded] = true
          entry[:approved] = (decision.to_s == "approve")
          entry[:reason] = reason
          entry[:condition].signal
          true
        end
      end

      # Cancel all pending permission requests (e.g., on session shutdown).
      def cancel_all!
        @mutex.synchronize do
          @pending.each_value do |entry|
            entry[:responded] = true
            entry[:approved] = false
            entry[:reason] = "Permission request cancelled"
            entry[:condition].signal
          end
          @pending.clear
        end
      end

      # Number of pending permission requests.
      def pending_count
        @mutex.synchronize { @pending.size }
      end

      # Are there any pending permission requests?
      def pending?
        pending_count > 0
      end

      private

      def request_approval(tool_call)
        request_id = SecureRandom.uuid
        condition = ConditionVariable.new

        @mutex.synchronize do
          @pending[request_id] = {
            tool_call: tool_call,
            condition: condition,
            responded: false,
            approved: false,
            reason: nil,
            created_at: Time.now
          }
        end

        @logger.debug("Requesting permission for #{tool_call.name} (#{request_id})")

        # Send the permission request via the registered callback
        @sender&.call(request_id, tool_call.name.to_s, tool_call.arguments)

        # Block the tool thread until the client responds
        response_reason = nil
        was_approved = false

        @mutex.synchronize do
          deadline = Time.now + @timeout

          loop do
            entry = @pending[request_id]
            break unless entry      # cancelled or already processed
            break if entry[:responded]  # response received

            remaining = deadline - Time.now
            if remaining <= 0
              @pending.delete(request_id)
              @logger.debug("Permission request #{request_id} timed out")
              return { action: :block, reason: "Permission request timed out after #{@timeout}s" }
            end

            condition.wait(@mutex, remaining)
          end

          entry = @pending.delete(request_id)
          if entry
            was_approved = entry[:approved]
            response_reason = entry[:reason]
          end
        end

        if was_approved
          @logger.debug("Permission granted for #{request_id}")
          { action: :proceed }
        else
          @logger.debug("Permission denied for #{request_id}: #{response_reason}")
          { action: :block, reason: response_reason || "Permission denied" }
        end
      rescue => e
        @pending.delete(request_id) rescue nil
        @logger.debug("Permission error: #{e.message}")
        { action: :block, reason: "Permission error: #{e.message}" }
      end
    end
  end
end
