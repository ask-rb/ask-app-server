# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    add_filter "/vendor/"
    track_files "lib/**/*.rb"
  end
end

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "ask-app-server"

require "ostruct"
require "json"
require "stringio"

require "minitest/autorun"
require "mocha/minitest" if Gem.loaded_specs.key?("mocha")

module AppServerTestHelpers
  # Build a fake ask-agent session for testing the adapter.
  # Returns a mock that responds like Ask::Agent::Session.
  def fake_agent_session(id: "test-session-id")
    session = mock("ask-agent-session")
    session.stubs(:id).returns(id)
    session.stubs(:run).returns("done")
    session.stubs(:abort)
    session.stubs(:on_event)
    session.stubs(:running?).returns(false)
    session
  end

  # Run a block with a temporary directory that gets cleaned up.
  def with_tempdir
    dir = Dir.mktmpdir("ask-app-server-test")
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Fake LLM provider response for testing.
  def fake_provider_response(content: "Hello!", tool_calls: {})
    OpenStruct.new(
      content: content,
      tool_calls: tool_calls,
      tool_results: {},
      input_tokens: 10,
      output_tokens: 20,
      cost: 0.001
    )
  end
end
