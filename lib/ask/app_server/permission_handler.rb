# frozen_string_literal: true

require "ask/permissions"

module Ask
  module AppServer
    # Protocol-aware permission handler that integrates with ask-agent's
    # before_tool_call hook system.
    #
    # Decision logic is delegated to the shared ask-permissions policy
    # (PermissionRules + ApprovalQueue + ApprovalPolicy). This handler
    # preserves its blocking protocol API on top:
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

      attr_reader :mode, :queue, :rules, :policy

      # @param mode [Symbol] :on_request (ask for dangerous tools) or :never (allow all)
      # @param blocked_tools [Array<Symbol>] list of tool names that require permission
      # @param timeout [Integer] seconds to wait for client response
      def initialize(mode: :on_request, blocked_tools: nil, timeout: DEFAULT_TIMEOUT)
        @mode = mode
        @blocked_tools = (blocked_tools || DEFAULT_BLOCKED_TOOLS).map(&:to_sym)
        @timeout = timeout
        @waiters = {}
        @sender = nil
        @mutex = Mutex.new
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)

        @rules = Ask::Permissions::PermissionRules.new
        @blocked_tools.each { |tool| @rules.ask(tool.to_s) }

        @queue = Ask::Permissions::ApprovalQueue.new(
          on_submit: ->(action) { @sender&.call(action.id.to_s, action.tool_name.to_s, action.args) }
        )

        @policy = Ask::Permissions::ApprovalPolicy.new(
          queue: @queue,
          rules: @rules,
          require_approval: (@mode != :never),
          tools: @blocked_tools.map(&:to_s)
        )
      end

      # Register a callback for sending the protocol message.
      # The callback receives (request_id, tool_name, tool_arguments).
      def on_request(&block)
        @sender = block
      end

      # Hook interface for Ask::Agent::Session's before_tool_call chain.
      # Returns { action: :proceed } or { action: :block, reason: "..." }.
      def before_tool_call(tool_call, context = nil)
        return { action: :proceed } if @mode == :never

        result = @policy.before_tool_call(tool_call, context)

        case result[:action]
        when :proceed
          { action: :proceed }
        when :block
          { action: :block, reason: result[:reason] || "Permission denied" }
        when :pending
          action_id = result[:action_id]
          return { action: :block, reason: "Permission error: missing action id" } if action_id.nil?

          wait_for_approval(action_id)
        else
          { action: :block, reason: "Permission error: unknown policy decision" }
        end
      rescue => e
        @logger.debug("Permission error: #{e.message}")
        { action: :block, reason: "Permission error: #{e.message}" }
      end

      # Called by the server when the client responds to a permission request.
      #
      # @param request_id [String] the ID that was sent in the permission request
      # @param decision [String] "approve" or "deny"
      # @param reason [String, nil] optional reason from the client
      def handle_response(request_id, decision, reason: nil)
        action_id = parse_action_id(request_id)
        return false if action_id.nil?

        @mutex.synchronize do
          action = @queue[action_id]
          entry = @waiters[action_id]
          return false if action.nil? && entry.nil?
          return false if !action.nil? && !action.pending? && entry.nil?

          if decision.to_s == "approve"
            @queue.approve(action_id)
          else
            @queue.reject(action_id)
          end

          if entry
            entry[:responded] = true
            entry[:approved] = (decision.to_s == "approve")
            entry[:reason] = reason
            entry[:condition].signal
          end
          true
        end
      end

      # Cancel all pending permission requests (e.g., on session shutdown).
      def cancel_all!
        @mutex.synchronize do
          @waiters.each_value do |entry|
            entry[:responded] = true
            entry[:approved] = false
            entry[:reason] = "Permission request cancelled"
            entry[:condition].signal
          end
          @waiters.clear
        end
        @queue.reject_all
      end

      # Number of pending permission requests.
      def pending_count
        @queue.pending_actions.size
      end

      # Are there any pending permission requests?
      def pending?
        @queue.any_pending?
      end

      private

      def parse_action_id(request_id)
        return request_id if request_id.is_a?(Integer)
        return nil if request_id.nil?

        str = request_id.to_s
        return nil unless str.match?(/\A\d+\z/)

        str.to_i
      end

      def wait_for_approval(action_id)
        condition = ConditionVariable.new

        @mutex.synchronize do
          # If the response already landed before we registered, consume it.
          action = @queue[action_id]
          if action && action.approved?
            @waiters.delete(action_id)
            return { action: :proceed }
          elsif action && action.rejected?
            @waiters.delete(action_id)
            return { action: :block, reason: "Permission denied" }
          end

          @waiters[action_id] = {
            condition: condition,
            responded: false,
            approved: false,
            reason: nil,
            created_at: Time.now
          }
        end

        @logger.debug("Requesting permission (#{action_id})")

        was_approved = false
        response_reason = nil

        @mutex.synchronize do
          deadline = Time.now + @timeout

          loop do
            entry = @waiters[action_id]
            break unless entry # cancelled

            # Fast-path: queue already resolved (handles approve-before-wait race).
            action = @queue[action_id]
            if action && action.approved?
              entry[:approved] = true
              entry[:responded] = true
            elsif action && action.rejected? && !entry[:responded]
              entry[:responded] = true
              entry[:approved] = false
            end

            break if entry[:responded]

            remaining = deadline - Time.now
            if remaining <= 0
              @waiters.delete(action_id)
              @queue.reject(action_id)
              @logger.debug("Permission request #{action_id} timed out")
              return { action: :block, reason: "Permission request timed out after #{@timeout}s" }
            end

            condition.wait(@mutex, remaining)
          end

          entry = @waiters.delete(action_id)
          if entry
            was_approved = entry[:approved]
            response_reason = entry[:reason]
          else
            # Cancelled via cancel_all! (entry cleared after signal).
            return { action: :block, reason: "Permission request cancelled" }
          end
        end

        if was_approved
          @logger.debug("Permission granted for #{action_id}")
          { action: :proceed }
        else
          @logger.debug("Permission denied for #{action_id}: #{response_reason}")
          { action: :block, reason: response_reason || "Permission denied" }
        end
      rescue => e
        @mutex.synchronize { @waiters.delete(action_id) } rescue nil
        @queue.reject(action_id) rescue nil
        @logger.debug("Permission error: #{e.message}")
        { action: :block, reason: "Permission error: #{e.message}" }
      end
    end
  end
end
