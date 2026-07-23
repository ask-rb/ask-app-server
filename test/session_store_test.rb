# frozen_string_literal: true

require_relative "test_helper"

class SessionStoreTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    @store = Ask::AppServer::SessionStore.new
    @adapter = stub("adapter", session_id: "sid-1", created_at: Time.now, running: false, idle?: true)
  end

  def test_add_and_get
    @store.add("sid-1", @adapter)
    assert_equal @adapter, @store.get("sid-1")
  end

  def test_add_duplicate_raises
    @store.add("sid-1", @adapter)
    assert_raises(Ask::AppServer::SessionAlreadyExists) do
      @store.add("sid-1", @adapter)
    end
  end

  def test_get_nonexistent_returns_nil
    assert_nil @store.get("nonexistent")
  end

  def test_remove
    @store.add("sid-1", @adapter)
    @store.remove("sid-1")
    assert_nil @store.get("sid-1")
  end

  def test_list
    adapter2 = stub("adapter2", session_id: "sid-2", created_at: Time.now, running: false, idle?: true)

    @store.add("sid-1", @adapter)
    @store.add("sid-2", adapter2)

    list = @store.list
    assert_equal 2, list.length
    assert list.any? { |s| s[:sessionId] == "sid-1" }
    assert list.any? { |s| s[:sessionId] == "sid-2" }
  end

  def test_list_respects_limit
    adapter2 = stub("adapter2", session_id: "sid-2", created_at: Time.now, running: false, idle?: true)

    @store.add("sid-1", @adapter)
    @store.add("sid-2", adapter2)

    assert_equal 1, @store.list(limit: 1).length
  end

  def test_subscribe_and_unsubscribe
    @store.add("sid-1", @adapter)

    refute @store.subscribed?("sid-1")

    @store.subscribe("sid-1", delivery_kind: "web-remote-replayable")
    assert @store.subscribed?("sid-1")

    @store.unsubscribe("sid-1")
    refute @store.subscribed?("sid-1")
  end

  def test_subscribe_nonexistent_raises
    assert_raises(Ask::AppServer::SessionNotFound) do
      @store.subscribe("nonexistent", delivery_kind: "test")
    end
  end

  def test_clear
    @store.add("sid-1", @adapter)
    @store.clear
    assert_equal 0, @store.count
  end

  def test_each
    @store.add("sid-1", @adapter)
    found = []
    @store.each { |a| found << a }
    assert_equal [@adapter], found
  end

  def test_thread_safety
    threads = 10.times.map do |i|
      Thread.new do
        100.times do |j|
          sid = "sid-#{i}-#{j}"
          adapter = stub("a", session_id: sid, created_at: Time.now, running: false, idle?: true)
          @store.add(sid, adapter)
          @store.get(sid)
          @store.remove(sid)
        end
      end
    end
    threads.each(&:join)
    assert_equal 0, @store.count
  end
end
