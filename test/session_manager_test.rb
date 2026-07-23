# frozen_string_literal: true

require_relative "test_helper"

class SessionManagerTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @manager = Ask::AppServer::SessionManager.new
  end

  def test_create_session
    session_id = @manager.create_session(
      workspace_path: "/tmp",
      model: "gpt-4o",
      tools: ["bash", "read"]
    )

    assert session_id, "should return a session ID"
    assert session_id.is_a?(String), "session ID should be a string"
    refute_empty session_id

    adapter = @manager.get(session_id)
    assert adapter, "adapter should exist"
    assert_equal session_id, adapter.session_id
  end

  def test_create_session_with_defaults
    session_id = @manager.create_session
    assert session_id, "should create with defaults"
  end

  def test_create_and_destroy
    session_id = @manager.create_session
    assert @manager.destroy_session(session_id), "destroy should return true"

    assert_nil @manager.get(session_id), "session should be gone"
    assert_equal 0, @manager.store.count
  end

  def test_destroy_nonexistent_returns_false
    refute @manager.destroy_session("nonexistent")
  end

  def test_list_sessions
    sid1 = @manager.create_session(workspace_path: "/tmp")
    sid2 = @manager.create_session(workspace_path: "/tmp")

    list = @manager.list_sessions
    assert list.length >= 2
    session_ids = list.map { |s| s[:sessionId] }
    assert_includes session_ids, sid1
    assert_includes session_ids, sid2
  end

  def test_send_message_requires_session
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.send_message("nonexistent", "hello")
    end
  end

  def test_subscribe
    session_id = @manager.create_session

    result = @manager.subscribe(session_id, delivery_kind: "test")
    assert result[:subscribed]
    assert_equal session_id, result[:sessionId]

    assert @manager.subscribed?(session_id)
  end

  def test_subscribe_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.subscribe("nonexistent")
    end
  end

  def test_get_events_empty
    session_id = @manager.create_session
    result = @manager.get_events(session_id, after_seq: 0)
    assert_equal session_id, result[:sessionId]
    assert_empty result[:events]
  end

  def test_get_events_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @manager.get_events("nonexistent", after_seq: 0)
    end
  end

  def test_read_workspace_state
    state = @manager.read_workspace_state
    assert state[:settings]
    assert state.dig(:settings, :model, :current, :modelId), "should have model"
    assert state.dig(:settings, :model, :current, :providerId), "should have provider"
  end
end
