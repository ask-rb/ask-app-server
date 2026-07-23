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

# Register default models needed for tests into the model catalog.
# This ensures SessionManager's DEFAULT_MODEL can be resolved.
module AskAppServerTestModels
  def self.register_default_models!
    catalog = Ask::ModelCatalog.instance
    return unless catalog.respond_to?(:register)

    models = [
      { id: "deepseek-v4-flash", provider: "opencode_go", context: 1_000_000, output: 384_000 },
      { id: "gpt-4o", provider: "openai", context: 128_000, output: 16_384 },
      { id: "gpt-4o-mini", provider: "openai", context: 128_000, output: 16_384 },
      { id: "claude-sonnet-4", provider: "anthropic", context: 200_000, output: 8_192 },
      { id: "gemini-2.0-flash", provider: "google", context: 1_000_000, output: 8_192 }
    ]

    models.each do |m|
      model = OpenStruct.new(
        id: m[:id],
        provider: m[:provider],
        chat?: true,
        context: m[:context],
        output: m[:output]
      )
      catalog.register(model)
    end
  end
end

AskAppServerTestModels.register_default_models!

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
