# frozen_string_literal: true

module Ask
  module AppServer
    # Wraps an Ask::Agent::Session and translates its events into the
    # app-server protocol event format via EventTranslator.
    #
    # Each wrapper is associated with one session and maintains an
    # EventTranslator that app-server clients poll or subscribe to.
    class AgentAdapter
      # The underlying ask-agent session.
      attr_reader :session

      # The event translator that accumulates protocol events.
      attr_reader :translator

      # The session ID (same as ask-agent session id).
      attr_reader :session_id

      # Whether a turn is currently in progress.
      attr_reader :running

      # When the session was created.
      attr_reader :created_at

      def initialize(model:, tools: nil, system_prompt: nil, agent_dir: nil, **session_opts)
        @model = model
        @system_prompt = system_prompt
        @tools = resolve_tools(tools)
        @session_opts = session_opts
        @agent_dir = agent_dir
        @session = nil
        @translator = nil
        @session_id = nil
        @running = false
        @running_mutex = Mutex.new
        @run_thread = nil
        @abort_requested = false
        @created_at = Time.now
        @logger = Logger.new($stdout, level: ENV["DEBUG"] ? Logger::DEBUG : Logger::WARN)
      end

      # Start a new ask-agent session.
      # Returns the session ID.
      def start_session
        @session = Ask::Agent::Session.new(
          model: @model,
          tools: @tools,
          system_prompt: @system_prompt,
          agent_dir: @agent_dir,
          **@session_opts
        )
        @session_id = @session.id
        @translator = EventTranslator.new(@session_id)
        @session.on_event { |event| handle_agent_event(event) }
        @session_id
      end

      # Resume an existing session (re-attach event handler).
      def resume(session)
        @session = session
        @session_id = session.id
        @translator = EventTranslator.new(@session_id)
        @session.on_event { |event| handle_agent_event(event) }
        @session_id
      end

      # Send a message and start processing. Runs in a background thread.
      # The caller should poll or subscribe to receive events.
      def send_message(content)
        raise "Session not started" unless @session
        raise "Session already busy" if @running

        @running_mutex.synchronize do
          @abort_requested = false
          @running = true
        end

        @run_thread = Thread.new do
          begin
            @session.run(content)
          rescue => e
            # Agent may have been aborted — that's fine
            @logger.debug("Agent run error: #{e.message}") if ENV["DEBUG"]
          ensure
            @running_mutex.synchronize { @running = false }
          end
        end

        true
      end

      # Request abort of the current turn.
      def abort_turn!
        @abort_requested = true
        @session&.abort if @session
      end

      # Wait for the current turn to complete (with timeout).
      # Returns true if completed, false if timed out.
      def wait_for_turn(timeout: 600)
        thread = @run_thread
        return true unless thread

        thread.join(timeout)
        !thread.alive?
      end

      # Whether this session is idle (no turn running).
      def idle?
        !@running
      end

      # Inject a message into a running session (mid-execution).
      # Aborts the current turn; the message will be processed when
      # the next turn starts.
      # Note: ask-agent doesn't natively support mid-execution injection.
      # We abort and queue the message for the next run.
      def inject_message(content)
        if @running
          abort_turn!
          # The caller should wait for idle, then call send_message again
          false
        else
          send_message(content)
          true
        end
      end

      # The accumulated streaming text from the current/ last turn.
      def streaming_text
        @translator&.instance_variable_get(:@streaming_text).to_s
      end

      # All events since last drain.
      def pending_events
        @translator&.pending_events || []
      end

      # Drain and return pending events.
      def drain_events
        @translator&.drain_events || []
      end

      # Last sequence number.
      def last_seq
        @translator&.last_seq || 0
      end

      # Events after a given sequence number.
      def events_after(after_seq)
        pending_events.select { |e| e[:seq] > after_seq }
      end

      private

      def handle_agent_event(event)
        translated = @translator.translate(event)
        # Translated events are already stored in the translator's buffer.
        # Nothing else to do here — clients poll or subscribe to get them.
      end

      def resolve_tools(tool_list)
        return default_tools if tool_list.nil?

        tool_list.map do |t|
          case t
          when Class then t.new
          when String then resolve_tool_by_name(t)
          else t
          end
        end
      end

      def resolve_tool_by_name(name)
        case name.downcase
        when "bash" then Ask::Tools::Bash.new
        when "read" then Ask::Tools::Read.new
        when "write" then Ask::Tools::Write.new
        when "edit" then Ask::Tools::Edit.new
        when "glob" then Ask::Tools::Glob.new
        when "grep" then Ask::Tools::Grep.new
        when "code" then Ask::Tools::Code.new
        else raise ArgumentError, "Unknown tool: #{name}"
        end
      end

      def default_tools
        [
          Ask::Tools::Bash.new,
          Ask::Tools::Read.new,
          Ask::Tools::Write.new,
          Ask::Tools::Edit.new,
          Ask::Tools::Glob.new,
          Ask::Tools::Grep.new
        ]
      end
    end
  end
end
