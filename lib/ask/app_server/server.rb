# frozen_string_literal: true

require "json"

module Ask
  module AppServer
    # JSON-RPC server implementing the ZCode/Codex app-server protocol over stdio.
    #
    # Communicates via NDJSON (Newline-Delimited JSON) over stdin/stdout.
    # Supports session management, streaming events, and mid-execution injection.
    #
    # Protocol methods:
    #   session/create, session/list, session/resume, session/subscribe,
    #   session/send, session/events, session/abort, workspace/readState
    #
    # Notifications (server → client):
    #   session/event, interaction/requestPermission, interaction/requestUserInput
    class Server
      def initialize(session_manager: nil)
        @session_manager = session_manager || SessionManager.new
        @running = false
        @input_queue = Queue.new
        @request_id = 0
        @pending_requests = {}  # request_id => { method:, params:, start_time: }
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)

        # Register the protocol handlers
        @handlers = {}
        register_default_handlers
      end

      # Start the server — reads from stdin in a background thread.
      # The main thread handles event pushing and shutdown.
      def start
        @running = true

        # Reader thread: reads NDJSON lines from stdin
        @reader = Thread.new do
          while @running
            begin
              line = $stdin.gets
              break unless line
              line = line.strip
              next if line.empty?

              @input_queue << JSON.parse(line)
            rescue JSON::ParserError => e
              send_error(nil, -32700, "Parse error: #{e.message}")
            rescue => e
              @logger.error("Reader error: #{e.message}")
              break
            end
          end
          @input_queue << nil  # signal shutdown
        end

        # Event push thread: polls subscribed sessions and pushes notifications
        @pusher = Thread.new do
          while @running
            push_session_events
            sleep 0.1  # 100ms poll interval
          end
        end

        # Main loop: processes incoming requests
        while @running
          msg = @input_queue.pop
          break if msg.nil?

          handle_message(msg)
        end
      rescue => e
        @logger.error("Server error: #{e.message}")
        raise
      ensure
        @running = false
        @reader&.kill rescue nil
        @pusher&.kill rescue nil
      end

      # Stop the server.
      def stop
        @running = false
      end

      # Whether the server is running.
      def running?
        @running
      end

      private

      def register_default_handlers
        # Initialize handshake
        handler("initialize") do |params, _id|
          {
            protocolVersion: "2025-01-01",
            capabilities: {
              sessionManagement: true,
              eventStreaming: true,
              midExecutionInjection: true,
              permissions: false
            },
            serverInfo: {
              name: "ask-app-server",
              version: Ask::AppServer::VERSION
            }
          }
        end

        # Session: create
        handler("session/create") do |params, _id|
          workspace = params["workspace"] || params[:workspace] || {}
          workspace_path = workspace["workspacePath"] || workspace[:workspacePath]
          mode = params["mode"] || params[:mode]
          model = params["model"] || params[:model] || ENV["ASK_APP_SERVER_MODEL"]
          tools = params["tools"] || params[:tools]
          system_prompt = params["systemPrompt"] || params[:system_prompt]

          session_id = @session_manager.create_session(
            workspace_path: workspace_path,
            mode: mode,
            model: model,
            tools: tools,
            system_prompt: system_prompt
          )

          adapter = @session_manager.get(session_id)

          {
            session: {
              sessionId: session_id,
              model: adapter&.instance_variable_get(:@model) || model,
              createdAt: adapter&.created_at&.iso8601
            }
          }
        end

        # Session: list
        handler("session/list") do |params, _id|
          limit = params["limit"] || params[:limit] || 20
          sessions = @session_manager.list_sessions(limit: limit)
          { sessions: sessions }
        end

        # Session: resume
        handler("session/resume") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          adapter = @session_manager.get(session_id)
          raise SessionNotFound, "Session #{session_id} not found" unless adapter

          {
            sessionId: session_id,
            running: adapter.running,
            idle: adapter.idle?,
            createdAt: adapter.created_at.iso8601
          }
        end

        # Session: subscribe
        handler("session/subscribe") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          delivery_kind = params["deliveryKind"] || params[:deliveryKind] || "web-remote-replayable"
          after_seq = params["afterSeq"] || params[:afterSeq] || 0
          include_snapshot = params["includeSnapshot"] || params[:includeSnapshot] || false

          result = @session_manager.subscribe(session_id, delivery_kind: delivery_kind)

          # If after_seq > 0, include snapshot of events since that sequence
          snapshot = if include_snapshot
            @session_manager.get_events(session_id, after_seq: after_seq)
          else
            nil
          end

          result.merge(snapshot: snapshot).compact
        end

        # Session: send
        handler("session/send") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          content = params["content"] || params[:content]

          raise InvalidRequest, "sessionId is required" unless session_id
          raise InvalidRequest, "content is required" unless content

          @session_manager.send_message(session_id, content.to_s)

          # Return immediately; events flow via subscription notifications.
          { accepted: true, sessionId: session_id }
        end

        # Session: events (polling)
        handler("session/events") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          after_seq = params["afterSeq"] || params[:afterSeq] || 0
          limit = params["limit"] || params[:limit]

          @session_manager.get_events(session_id, after_seq: after_seq, limit: limit)
        end

        # Session: abort
        handler("session/abort") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          adapter = @session_manager.get(session_id)
          raise SessionNotFound, "Session #{session_id} not found" unless adapter

          adapter.abort_turn!
          { aborted: true, sessionId: session_id }
        end

        # Workspace: read state
        handler("workspace/readState") do |params, _id|
          workspace = params["workspace"] || params[:workspace] || {}
          workspace_path = workspace["workspacePath"] || workspace[:workspacePath]

          @session_manager.read_workspace_state
        end

        # Interaction: respond to permission request
        handler("interaction/requestPermission") do |params, _id|
          # Permission requests come from the server to the client.
          # This handler is for the client's response.
          { handled: true }
        end
      end

      def handler(method, &block)
        @handlers[method] = block
      end

      def handle_message(msg)
        method = msg["method"] || msg[:method]
        params = msg["params"] || msg[:params] || {}
        id = msg["id"] || msg[:id]

        unless method
          send_error(id, -32600, "Method not specified") if id
          return
        end

        handler_block = @handlers[method]
        unless handler_block
          send_error(id, -32601, "Method not found: #{method}") if id
          return
        end

        begin
          result = handler_block.call(params, id)
          send_result(id, result) if id
        rescue SessionNotFound => e
          send_error(id, -32004, e.message) if id
        rescue SessionAlreadyExists => e
          send_error(id, -32005, e.message) if id
        rescue InvalidRequest => e
          send_error(id, -32602, e.message) if id
        rescue => e
          @logger.error("Handler error for #{method}: #{e.message}")
          send_error(id, -32603, "Internal error: #{e.message}") if id
        end
      end

      def send_result(id, result)
        write_line({ id: id, result: result })
      end

      def send_error(id, code, message)
        response = { id: id, error: { code: code, message: message } }
        write_line(response)
      end

      def send_notification(method, params)
        write_line({ method: method, params: params })
      end

      def write_line(msg)
        $stdout.puts(JSON.generate(msg))
        $stdout.flush
      end

      # Push session/event notifications for subscribed sessions.
      def push_session_events
        @session_manager.store.each do |adapter|
          sid = adapter.session_id
          next unless @session_manager.subscribed?(sid)

          events = adapter.drain_events
          next if events.empty?

          events.each do |ev|
            send_notification("session/event", ev)
          end
        end
      rescue => e
        # Don't crash the push thread
        @logger.error("Push error: #{e.message}") if ENV["DEBUG"]
      end
    end
  end
end
