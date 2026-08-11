# frozen_string_literal: true

require_relative "test_helper"

class ConnectionTest < Minitest::Test
  def setup
    @input = StringIO.new
    @output = StringIO.new
    @connection = Ask::AppServer::Connection.new(@input, @output)
  end

  def test_initial_state
    assert_empty @connection.subscriptions
    refute @connection.subscribed?("sess_1")
    assert_equal 0, @connection.cursor("sess_1")
  end

  def test_write_emits_ndjson
    @connection.write({ method: "session/event", params: { event: { "type" => "error", "seq" => 1, "payload" => {} } } })
    line = @output.string.lines.first
    assert_equal "session/event", JSON.parse(line)["method"]
  end

  def test_subscribe_sets_cursor
    @connection.subscribe("sess_1", after_seq: 5)
    assert @connection.subscribed?("sess_1")
    assert_equal 5, @connection.cursor("sess_1")
  end

  def test_subscribe_defaults_to_replay
    @connection.subscribe("sess_1")
    assert_equal 0, @connection.cursor("sess_1")
  end

  def test_advance_only_while_subscribed
    @connection.advance("sess_1", 9)
    assert_equal 0, @connection.cursor("sess_1"), "advance on an unsubscribed session is ignored"

    @connection.subscribe("sess_1", after_seq: 3)
    @connection.advance("sess_1", 7)
    assert_equal 7, @connection.cursor("sess_1")
  end

  def test_unsubscribe
    @connection.subscribe("sess_1")
    @connection.unsubscribe("sess_1")
    refute @connection.subscribed?("sess_1")
  end

  def test_close_drops_all_subscriptions
    @connection.subscribe("sess_1")
    @connection.subscribe("sess_2")
    @connection.close
    assert_empty @connection.subscriptions
  end

  def test_cursors_are_isolated_per_session
    @connection.subscribe("sess_1", after_seq: 1)
    @connection.subscribe("sess_2", after_seq: 10)
    @connection.advance("sess_1", 2)

    assert_equal 2, @connection.cursor("sess_1")
    assert_equal 10, @connection.cursor("sess_2")
  end
end
