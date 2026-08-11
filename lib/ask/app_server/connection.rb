# frozen_string_literal: true

require "json"

module Ask
  module AppServer
    # A client connection to the session host: an input/output pair (stdio
    # or a unix socket) plus the connection's per-session event delivery
    # cursors.
    #
    # Delivery is cursor-based: the connection tracks the last delivered
    # seq for each subscribed session, so any number of clients can attach
    # to the same sessions and each receives exactly the events after its
    # own cursor. Subscribe with afterSeq to replay; clients dedup by seq.
    class Connection
      # session_id => last delivered seq
      attr_reader :subscriptions

      # @param input [IO] source of NDJSON lines (responds to gets)
      # @param output [IO] sink for NDJSON responses/notifications
      def initialize(input, output)
        @input = input
        @output = output
        @subscriptions = {}
        @mutex = Mutex.new
      end

      # Read one line from the input, or nil on EOF/disconnect.
      def read_line
        @input.gets
      end

      # Write one JSON-RPC message (Hash) to the output.
      def write(msg)
        @output.puts(JSON.generate(msg))
        @output.flush
      end

      # Whether the connection is subscribed to a session.
      def subscribed?(session_id)
        @mutex.synchronize { @subscriptions.key?(session_id) }
      end

      # Subscribe to a session, starting delivery after after_seq.
      def subscribe(session_id, after_seq: 0)
        @mutex.synchronize { @subscriptions[session_id] = after_seq.to_i }
      end

      # Unsubscribe from a session.
      def unsubscribe(session_id)
        @mutex.synchronize { @subscriptions.delete(session_id) }
      end

      # The last delivered seq for a session (0 = replay from the start).
      def cursor(session_id)
        @mutex.synchronize { @subscriptions[session_id] || 0 }
      end

      # Advance the delivery cursor for a session (only while subscribed).
      def advance(session_id, seq)
        @mutex.synchronize do
          @subscriptions[session_id] = seq if @subscriptions.key?(session_id)
        end
      end

      # Drop all subscriptions. Does not close the underlying I/O — the
      # owner (the server) manages IO lifecycle.
      def close
        @mutex.synchronize { @subscriptions.clear }
      end
    end
  end
end
