# frozen_string_literal: true

require_relative "test_helper"

class AgentAdapterTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @adapter = Ask::AppServer::AgentAdapter.new(
      model: "gpt-4o",
      tools: ["bash", "read"],
      system_prompt: "You are a test assistant."
    )
  end

  def test_start_session_returns_id
    session_id = @adapter.start_session
    assert session_id, "should return a session ID"
    assert_equal @adapter.session_id, session_id
  end

  def test_session_has_translator
    @adapter.start_session
    assert @adapter.translator, "should have an event translator"
    assert_equal @adapter.session_id, @adapter.translator.session_id
  end

  def test_default_tools
    adapter = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    assert adapter.send(:default_tools).length >= 5, "should have default tools"
  end

  def test_resolve_tool_by_name
    bash = @adapter.send(:resolve_tool_by_name, "bash")
    assert bash.is_a?(Ask::Tools::Bash)

    read = @adapter.send(:resolve_tool_by_name, "read")
    assert read.is_a?(Ask::Tools::Read)
  end

  def test_resolve_unknown_tool_raises
    assert_raises(ArgumentError) do
      @adapter.send(:resolve_tool_by_name, "nonexistent_tool")
    end
  end

  def test_initial_state
    refute @adapter.running
    assert @adapter.idle?
    assert_nil @adapter.session_id
  end

  def test_abort_turn_when_not_running
    @adapter.start_session
    @adapter.abort_turn!  # Should not raise
    assert true
  end

  def test_double_start_session_creates_new
    id1 = @adapter.start_session
    # Starting a new adapter again would be a fresh session
    adapter2 = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    id2 = adapter2.start_session
    refute_equal id1, id2, "should create different session IDs"
  end

  def test_pending_events_empty_initially
    @adapter.start_session
    assert_empty @adapter.pending_events
    assert_equal 0, @adapter.last_seq
  end

  def test_events_after_returns_empty_initially
    @adapter.start_session
    assert_empty @adapter.events_after(0)
  end

  def test_send_message_requires_session
    assert_raises(RuntimeError, "Session not started") do
      @adapter.send_message("hello")
    end
  end

  def test_drain_events
    @adapter.start_session
    assert_empty @adapter.drain_events
  end

  def test_resume_re_attaches_handler
    @adapter.start_session
    session = @adapter.session

    adapter2 = Ask::AppServer::AgentAdapter.new(model: "gpt-4o")
    adapter2.resume(session)
    assert_equal session.id, adapter2.session_id
    assert adapter2.translator
  end
end
