# frozen_string_literal: true

require_relative "test_helper"

class PermissionHandlerTest < Minitest::Test
  def setup
    @handler = Ask::AppServer::PermissionHandler.new
    @sender_calls = []
  end

  # --- Construction ---

  def test_default_mode_is_on_request
    assert_equal :on_request, @handler.mode
  end

  def test_custom_mode
    handler = Ask::AppServer::PermissionHandler.new(mode: :never)
    assert_equal :never, handler.mode
  end

  def test_custom_blocked_tools
    handler = Ask::AppServer::PermissionHandler.new(blocked_tools: %w[rm destroy], timeout: 0.05)
    tool_call = make_tool_call("rm")
    handler.on_request { |*args| @sender_calls << args }
    result = handler.before_tool_call(tool_call)
    assert_equal :block, result[:action], "custom blocked tool should be blocked"
  end

  def test_default_blocked_tools
    %w[write edit bash destroy].each do |tool|
      tool_call = make_tool_call(tool)
      handler = Ask::AppServer::PermissionHandler.new(timeout: 0.05)
      sent = []
      handler.on_request { |*args| sent << args }

      result = handler.before_tool_call(tool_call)
      assert_equal :block, result[:action], "#{tool} should be blocked by default"
    end
  end

  # --- before_tool_call behavior ---

  def test_allows_non_blocked_tools
    tool_call = make_tool_call("read")
    result = @handler.before_tool_call(tool_call)
    assert_equal :proceed, result[:action]
  end

  def test_allows_all_in_never_mode
    handler = Ask::AppServer::PermissionHandler.new(mode: :never)

    %w[write edit bash destroy].each do |tool|
      tool_call = make_tool_call(tool)
      result = handler.before_tool_call(tool_call)
      assert_equal :proceed, result[:action], "#{tool} should proceed in never mode"
    end
  end

  def test_blocks_and_approves
    handler = Ask::AppServer::PermissionHandler.new
    sent = []
    handler.on_request { |*args| sent << args }

    thread = Thread.new { handler.before_tool_call(make_tool_call("write")) }
    wait_for_pending(handler, 1)

    assert_equal 1, sent.length
    assert_equal "write", sent[0][1]
    assert sent[0][2].include?('"/tmp/test"'), "should have tmp/test in arguments"

    handler.handle_response(sent[0][0], "approve")
    result = thread.value

    assert_equal :proceed, result[:action]
  end

  def test_deny_returns_block
    handler = Ask::AppServer::PermissionHandler.new
    sent = []
    handler.on_request { |*args| sent << args }

    thread = Thread.new { handler.before_tool_call(make_tool_call("bash")) }
    wait_for_pending(handler, 1)

    handler.handle_response(sent[0][0], "deny")
    result = thread.value

    assert_equal :block, result[:action]
  end

  def test_timeout_returns_block
    handler = Ask::AppServer::PermissionHandler.new(timeout: 0.1)
    sent = []
    handler.on_request { |*args| sent << args }

    result = handler.before_tool_call(make_tool_call("write"))

    assert_equal :block, result[:action]
    assert_includes result[:reason].to_s, "timed out"
  end

  # --- handle_response ---

  def test_handle_response_approve_returns_true
    sent = []
    @handler.on_request { |*args| sent << args }

    thread = Thread.new { @handler.before_tool_call(make_tool_call("write")) }
    wait_for_pending(@handler, 1)

    result = @handler.handle_response(sent[0][0], "approve")
    assert result, "handle_response should return true for valid request"

    thread.value  # drain
  end

  def test_handle_response_deny_returns_true
    sent = []
    @handler.on_request { |*args| sent << args }

    thread = Thread.new { @handler.before_tool_call(make_tool_call("write")) }
    wait_for_pending(@handler, 1)

    result = @handler.handle_response(sent[0][0], "deny")
    assert result

    thread.value  # drain
  end

  def test_handle_response_unknown_id_returns_false
    result = @handler.handle_response("nonexistent", "approve")
    refute result
  end

  # --- cancel_all! ---

  def test_cancel_all_unblocks_all
    handler = Ask::AppServer::PermissionHandler.new
    handler.on_request { |*| }

    threads = 3.times.map do
      Thread.new { handler.before_tool_call(make_tool_call("write")) }
    end
    wait_for_pending(handler, 3)

    assert handler.pending?
    assert_equal 3, handler.pending_count

    handler.cancel_all!
    results = threads.map(&:value)

    assert_equal 0, handler.pending_count
    results.each do |r|
      assert_equal :block, r[:action], "all should be blocked after cancel_all!"
    end
  end

  # --- sender callback ---

  def test_sender_callback_receives_correct_args
    handler = Ask::AppServer::PermissionHandler.new(timeout: 0.1)
    sent = []
    handler.on_request { |*args| sent << args }

    handler.before_tool_call(make_tool_call("bash", cmd: "rm -rf /"))

    assert_equal 1, sent.length
    request_id, tool_name, arguments = sent[0]

    assert request_id.is_a?(String)
    refute_empty request_id
    assert_equal "bash", tool_name
    assert arguments
  end

  def test_sender_not_required
    handler = Ask::AppServer::PermissionHandler.new(timeout: 0.05)
    result = handler.before_tool_call(make_tool_call("write"))
    assert_equal :block, result[:action]
  end

  # --- pending state ---

  def test_pending_count
    handler = Ask::AppServer::PermissionHandler.new
    handler.on_request { |*| }

    refute handler.pending?
    assert_equal 0, handler.pending_count

    thread = Thread.new { handler.before_tool_call(make_tool_call("write")) }
    wait_for_pending(handler, 1)

    assert handler.pending?
    assert_equal 1, handler.pending_count

    handler.cancel_all!
    thread.join(1)

    refute handler.pending?
    assert_equal 0, handler.pending_count
  end

  # --- thread safety ---

  def test_concurrent_permission_requests
    handler = Ask::AppServer::PermissionHandler.new
    request_ids = []
    mutex = Mutex.new
    handler.on_request do |req_id, *_|
      mutex.synchronize { request_ids << req_id }
    end

    threads = 5.times.map do
      Thread.new { handler.before_tool_call(make_tool_call("write")) }
    end
    wait_for_pending(handler, 5)

    assert_equal 5, request_ids.length
    assert_equal 5, request_ids.uniq.length

    request_ids.each { |id| handler.handle_response(id, "approve") }
    results = threads.map(&:value)

    results.each { |r| assert_equal :proceed, r[:action] }
  end

  private

  def wait_for_pending(handler, expected, timeout: 5)
    deadline = Time.now + timeout
    while handler.pending_count < expected && Time.now < deadline
      sleep 0.05
    end
    assert_equal expected, handler.pending_count,
      "Timed out waiting for #{expected} pending requests (got #{handler.pending_count})"
  end

  def make_tool_call(name, **extra_args)
    args = case name
    when "bash" then { "command" => extra_args[:cmd] || "echo hi" }
    when "write" then { "file" => "/tmp/test", "content" => "test" }
    when "edit" then { "file_path" => "/tmp/test", "old_string" => "a", "new_string" => "b" }
    when "destroy" then { "path" => "/tmp/test" }
    else extra_args.any? ? extra_args : {}
    end

    OpenStruct.new(
      id: "call_#{SecureRandom.hex(4)}",
      name: name,
      arguments: JSON.generate(args)
    )
  end
end
