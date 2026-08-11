# frozen_string_literal: true

require "json"
require "time"

module Ask
  module AppServer
    # JSON-RPC protocol engine implementing the canonical
    # Ask::SessionProtocol. The session host: owns agent sessions behind one
    # versioned contract that every client (terminal TUI, web console, bots,
    # IDE) speaks.
    #
    # The engine is transport-agnostic: messages arrive per-connection
    # ({#dispatch}) and responses/notifications are written back to the
    # requesting connection. Event delivery is cursor-based — each
    # connection tracks the last delivered seq per subscribed session
    # ({Connection}), so any number of clients can attach to the same
    # sessions. Two transports use the engine:
    #
    #   Server#start     — stdio mode (one Connection over stdin/stdout)
    #   SocketServer     — unix socket mode (a Connection per client)
    #
    # Client → host methods (see Ask::SessionProtocol::Methods):
    #   ping, initialize, session/create, session/list, session/resume,
    #   session/subscribe, session/events, session/send, session/abort,
    #   session/close, session/artifacts, session/artifact/get,
    #   interaction/list, interaction/approve, interaction/reject,
    #   interaction/approve-all, interaction/reject-all,
    #   interaction/respond, plan/approve, plan/reject, workspace/readState
    #
    # Host → client notifications:
    #   session/event — carries a canonical event envelope {type, seq, payload}
    #
    # The engine also handles incoming responses to its outgoing reverse
    # requests (interaction/requestPermission, interaction/requestUserInput
    # — the app-server interop surface).
    class Server
      # Host capabilities advertised in `initialize`. The host emits every
      # canonical event except file.changed today.
      HOST_CAPABILITIES =
        (Ask::SessionProtocol::Methods::CAPABILITIES - %w[fileEvents]).freeze

      def initialize(session_manager: nil)
        @session_manager = session_manager || SessionManager.new
        @running = false
        @started_at = nil
        @connections = []
        @connections_mutex = Mutex.new
        @response_handlers = {}  # outgoing request_id => Proc
        @outgoing_id = 0
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)

        # Register the protocol method handlers
        @handlers = {}
        register_default_handlers
      end

      attr_reader :session_manager

      # ── Connection registry ────────────────────────────────────────────

      # All live connections (snapshot).
      def connections
        @connections_mutex.synchronize { @connections.dup }
      end

      # Register a connection for dispatch and event delivery.
      def add_connection(connection)
        @connections_mutex.synchronize { @connections << connection }
        connection
      end

      # Deregister a connection (client disconnected).
      def remove_connection(connection)
        @connections_mutex.synchronize { @connections.delete(connection) }
        connection.close
      end

      # ── Transports ─────────────────────────────────────────────────────

      # Start the stdio transport: one Connection over stdin/stdout, a
      # reader thread dispatching messages, and a pusher delivering events.
      # Blocks until the input closes or {#stop} is called.
      def start
        @running = true
        @started_at = Time.now
        connection = add_connection(Connection.new($stdin, $stdout))

        @reader = Thread.new do
          reader_loop(connection)
        end
        @pusher = Thread.new { pusher_loop }

        @reader.join
        stop
      end

      # Stop the server.
      def stop
        @running = false
        @reader&.kill rescue nil
        @pusher&.kill rescue nil
      end

      # Whether the server is running.
      def running?
        @running
      end

      # ── Dispatch ───────────────────────────────────────────────────────

      # Process one JSON-RPC message from a connection. Requests are
      # validated against the contract before dispatch; responses and
      # errors are written back to `connection`.
      #
      # @param msg [Hash] parsed JSON-RPC message
      # @param connection [Connection] the sending connection
      def dispatch(msg, connection)
        id = msg["id"] || msg[:id]

        # Check if this is a response to an outgoing request.
        # A response has an id and a result (or error), but no method.
        if id && !msg.key?("method") && !msg.key?(:method)
          if msg.key?("result") || msg.key?(:result)
            handle_incoming_response(id, msg["result"] || msg[:result])
            return
          elsif msg.key?("error") || msg.key?(:error)
            handle_incoming_response(id, nil, msg["error"] || msg[:error])
            return
          end
        end

        method = msg["method"] || msg[:method]
        params = (msg["params"] || msg[:params] || {})
        params = params.transform_keys(&:to_s) if params.is_a?(Hash)

        unless method
          send_error(id, -32600, "Method not specified", connection) if id
          return
        end

        handler_block = @handlers[method]
        unless handler_block
          send_error(id, -32601, "Method not found: #{method}", connection) if id
          return
        end

        begin
          validate_request!(method, params)
          result = handler_block.call(params, id, connection)
          send_result(id, result, connection) if id
        rescue Ask::AppServer::SessionNotFound => e
          send_error(id, -32004, e.message, connection) if id
        rescue Ask::AppServer::SessionAlreadyExists => e
          send_error(id, -32005, e.message, connection) if id
        rescue Ask::AppServer::InteractionNotFound => e
          send_error(id, -32006, e.message, connection) if id
        rescue Ask::AppServer::PlanNotFound => e
          send_error(id, -32007, e.message, connection) if id
        rescue Ask::AppServer::InvalidRequest => e
          send_error(id, -32602, e.message, connection) if id
        rescue ArgumentError => e
          # Contract validation failures (invalid params)
          send_error(id, -32602, e.message, connection) if id
        rescue => e
          @logger.error("Handler error for #{method}: #{e.message}")
          send_error(id, -32603, "Internal error: #{e.message}", connection) if id
        end
      end

      # Send an outgoing JSON-RPC request to a client (reverse request).
      # If a block is given, it will be called with (result, error) when
      # the client responds. Defaults to the stdio transport ($stdout).
      def send_request(method, params, connection = nil, &block)
        id = next_outgoing_id
        @response_handlers[id] = block if block
        if connection
          connection.write({ id: id, method: method, params: params })
        else
          write_line({ id: id, method: method, params: params })
        end
        id
      end

      # ── Event push ─────────────────────────────────────────────────────

      # One delivery pass: for every subscribed connection, deliver the
      # events its sessions have produced since the connection's cursor,
      # then advance the cursor. Cursor-based, so each client receives
      # exactly the events after its own seq (replay on subscribe).
      def push_pending
        connections.each do |connection|
          connection.subscriptions.keys.each do |session_id|
            adapter = @session_manager.get(session_id)
            next unless adapter

            events = adapter.events_after(connection.cursor(session_id))
            next if events.empty?

            events.each do |ev|
              connection.write({ method: "session/event", params: { event: ev.to_h } })
            end
            connection.advance(session_id, events.last.seq)
          end
        end
      rescue => e
        @logger.debug("Push error: #{e.message}") if ENV["DEBUG"]
      end

      # ── Response/notification helpers ──────────────────────────────────

      def send_result(id, result, connection = nil)
        connection ? connection.write({ id: id, result: result }) : write_line({ id: id, result: result })
      end

      def send_error(id, code, message, connection = nil)
        response = { id: id, error: { code: code, message: message } }
        connection ? connection.write(response) : write_line(response)
      end

      def send_notification(method, params, connection = nil)
        msg = { method: method, params: params }
        connection ? connection.write(msg) : write_line(msg)
      end

      def write_line(msg)
        $stdout.puts(JSON.generate(msg))
        $stdout.flush
      end

      private

      def validate_request!(method, params)
        # Host-side contract enforcement: canonical client → host methods
        # validate their params against the protocol registry. Handlers
        # outside the canonical surface (e.g. the requestPermission query)
        # are exempt.
        return unless Ask::SessionProtocol::Methods.known?(method)

        Ask::SessionProtocol::Methods.validate_params!(method, params)
      end

      def next_outgoing_id
        @outgoing_id += 1
        # Use IDs starting from a high number to avoid collision with client IDs
        10_000 + @outgoing_id
      end

      def reader_loop(connection)
        while @running
          line = connection.read_line
          break unless line
          line = line.strip
          next if line.empty?

          begin
            dispatch(JSON.parse(line), connection)
          rescue JSON::ParserError => e
            send_error(nil, -32700, "Parse error: #{e.message}", connection)
          rescue => e
            @logger.error("Reader error: #{e.message}")
            break
          end
        end
      ensure
        remove_connection(connection)
      end

      def pusher_loop
        while @running
          push_pending
          sleep 0.1  # 100ms poll interval
        end
      end

      def handle_incoming_response(id, result, error = nil)
        handler_block = @response_handlers.delete(id)
        if handler_block
          handler_block.call(result, error)
        else
          @logger.debug("No handler for response #{id}")
        end
      end

      def register_default_handlers
        # Ping — liveness check
        handler("ping") do |_params, _id|
          {
            status: "ok",
            version: Ask::AppServer::VERSION,
            protocolVersion: Ask::SessionProtocol::PROTOCOL_VERSION,
            uptime: @started_at ? (Time.now - @started_at).to_i : 0,
            sessions: @session_manager&.store&.count || 0
          }
        end

        # Initialize handshake — negotiate the protocol version and
        # exchange capabilities.
        handler("initialize") do |_params, _id|
          {
            protocolVersion: Ask::SessionProtocol::PROTOCOL_VERSION,
            capabilities: HOST_CAPABILITIES,
            server: {
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
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

          {
            sessionId: session_id,
            running: adapter.running,
            idle: adapter.idle?,
            createdAt: adapter.created_at.iso8601
          }
        end

        # Session: subscribe — attach to the event stream with replay.
        # The connection's delivery cursor starts at afterSeq, so the
        # pusher delivers everything the client hasn't seen.
        handler("session/subscribe") do |params, _id, connection|
          session_id = params["sessionId"] || params[:sessionId]
          delivery_kind = params["deliveryKind"] || params[:deliveryKind] || "replay"
          after_seq = params["afterSeq"] || params[:afterSeq] || 0
          include_snapshot = params["includeSnapshot"] || params[:includeSnapshot] || false

          result = @session_manager.subscribe(session_id, delivery_kind: delivery_kind)
          connection.subscribe(session_id, after_seq: after_seq)

          if include_snapshot
            snapshot = @session_manager.get_events(session_id, after_seq: after_seq)
            result[:snapshot] = serialize_events(snapshot[:events])
          end

          result
        end

        # Session: send — prompt an idle session or inject mid-run.
        handler("session/send") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          content = params["content"] || params[:content]
          expected_turn_id = params["expectedTurnId"] || params[:expectedTurnId]

          raise InvalidRequest, "sessionId is required" unless session_id
          raise InvalidRequest, "content is required" unless content

          @session_manager.send_message(session_id, content, expected_turn_id: expected_turn_id)
        end

        # Session: events (polling)
        handler("session/events") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          after_seq = params["afterSeq"] || params[:afterSeq] || 0
          limit = params["limit"] || params[:limit]

          result = @session_manager.get_events(session_id, after_seq: after_seq, limit: limit)
          result[:events] = serialize_events(result[:events])
          result
        end

        # Session: abort
        handler("session/abort") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          adapter = @session_manager.get(session_id)
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

          adapter.abort_turn!
          { aborted: true, sessionId: session_id }
        end

        # Session: close
        handler("session/close") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          closed = @session_manager.close_session(session_id)
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless closed

          { closed: true, sessionId: session_id }
        end

        # Artifacts: list the session's tool deliverables
        handler("session/artifacts") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          adapter = @session_manager.get(session_id)
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

          agent = adapter.session
          raise InvalidRequest, "session has no artifact store (artifacts: not enabled)" unless agent.artifact_store

          { artifacts: agent.artifacts }
        end

        # Artifact: fetch one (content for inline artifacts, uri for
        # external binaries)
        handler("session/artifact/get") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          artifact_id = params["artifactId"] || params[:artifactId]
          raise InvalidRequest, "sessionId and artifactId are required" unless session_id && artifact_id

          adapter = @session_manager.get(session_id)
          raise Ask::AppServer::SessionNotFound, "Session #{session_id} not found" unless adapter

          agent = adapter.session
          raise InvalidRequest, "session has no artifact store (artifacts: not enabled)" unless agent.artifact_store

          record = agent.fetch_artifact(artifact_id)
          raise InvalidRequest, "Artifact #{artifact_id} not found" unless record

          { artifact: record }
        end

        # ── Interactions (resolvable by id from any client) ──────────────

        # Interaction: list pending approval interactions
        handler("interaction/list") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          interactions = @session_manager.pending_interactions(session_id)
          { interactions: interactions.map(&:to_h) }
        end

        # Interaction: approve by id
        handler("interaction/approve") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          interaction_id = params["interactionId"] || params[:interactionId]
          raise InvalidRequest, "sessionId and interactionId are required" unless session_id && interaction_id

          approved = @session_manager.approve_interaction(session_id, interaction_id)
          raise Ask::AppServer::InteractionNotFound, "Interaction #{interaction_id} not found" unless approved

          { approved: true, interactionId: interaction_id }
        end

        # Interaction: reject by id
        handler("interaction/reject") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          interaction_id = params["interactionId"] || params[:interactionId]
          raise InvalidRequest, "sessionId and interactionId are required" unless session_id && interaction_id

          rejected = @session_manager.reject_interaction(session_id, interaction_id)
          raise Ask::AppServer::InteractionNotFound, "Interaction #{interaction_id} not found" unless rejected

          { rejected: true, interactionId: interaction_id }
        end

        # Interaction: approve all pending
        handler("interaction/approve-all") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          { approved: @session_manager.approve_all_interactions(session_id) }
        end

        # Interaction: reject all pending
        handler("interaction/reject-all") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          { rejected: @session_manager.reject_all_interactions(session_id) }
        end

        # Interaction: respond to a user_input interaction (elicitation).
        # Not implemented: ask-agent has no elicitation surface yet.
        handler("interaction/respond") do |_params, id, connection|
          send_error(id, Ask::SessionProtocol::Methods::ERROR_CODES[:not_implemented],
                     "interaction/respond is not implemented: user input elicitation is not supported by the runtime",
                     connection)
        end

        # ── Plan mode ────────────────────────────────────────────────────

        # Plan: approve the pending proposal
        handler("plan/approve") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          approved = @session_manager.plan_approve(session_id)
          raise Ask::AppServer::PlanNotFound, "No pending plan for session #{session_id}" unless approved

          { approved: true }
        end

        # Plan: reject the pending proposal
        handler("plan/reject") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          raise InvalidRequest, "sessionId is required" unless session_id

          rejected = @session_manager.plan_reject(session_id)
          raise Ask::AppServer::PlanNotFound, "No pending plan for session #{session_id}" unless rejected

          { rejected: true }
        end

        # Workspace: read state
        handler("workspace/readState") do |params, _id|
          session_id = params["sessionId"] || params[:sessionId]
          @session_manager.read_workspace_state(session_id)
        end

        # Interaction: requestPermission — when a client sends this as a
        # request, respond with the current approval mode (interop query).
        handler("interaction/requestPermission") do |_params, _id|
          { mode: @session_manager.approval_mode.to_s, pending: false }
        end
      end

      def handler(method, &block)
        @handlers[method] = block
      end

      # Canonical Event objects → wire hashes.
      def serialize_events(events)
        events.map(&:to_h)
      end
    end
  end
end
