# frozen_string_literal: true

module Ask
  module AppServer
    class Error < StandardError; end
    class ProtocolError < Error; end
    class SessionNotFound < Error; end
    class SessionAlreadyExists < Error; end
    class SessionNotSubscribed < Error; end
    class InvalidRequest < Error; end
    class TimeoutError < Error; end
  end
end
