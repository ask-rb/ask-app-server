# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include AppServerTestHelpers

  def test_defaults
    config = Ask::AppServer::Config.new
    assert_equal "gpt-4o", config.model
    assert_equal %w[bash read write edit glob grep], config.tools
    assert_equal :on_request, config.permission_mode
    assert_equal %w[write edit bash destroy], config.blocked_tools
    assert_equal 300, config.permission_timeout
    assert_equal 600, config.session_timeout
    assert_nil config.system_prompt
    refute config.debug?
  end

  def test_env_var_overrides_model
    original = ENV.delete("ASK_APP_SERVER_MODEL")
    ENV["ASK_APP_SERVER_MODEL"] = "claude-sonnet-4"
    begin
      config = Ask::AppServer::Config.new
      assert_equal "claude-sonnet-4", config.model
    ensure
      if original
        ENV["ASK_APP_SERVER_MODEL"] = original
      else
        ENV.delete("ASK_APP_SERVER_MODEL")
      end
    end
  end

  def test_env_var_permissions
    original = ENV.delete("ASK_APP_SERVER_PERMISSIONS")
    ENV["ASK_APP_SERVER_PERMISSIONS"] = "never"
    begin
      config = Ask::AppServer::Config.new
      assert_equal :never, config.permission_mode
    ensure
      if original
        ENV["ASK_APP_SERVER_PERMISSIONS"] = original
      else
        ENV.delete("ASK_APP_SERVER_PERMISSIONS")
      end
    end
  end

  def test_debug_from_env
    original = ENV.delete("DEBUG")
    ENV["DEBUG"] = "1"
    begin
      config = Ask::AppServer::Config.new
      assert config.debug?
    ensure
      if original
        ENV["DEBUG"] = original
      else
        ENV.delete("DEBUG")
      end
    end
  end

  def test_load_from_file
    with_tempdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.pretty_generate({
        model: "gemini-2.0-flash",
        tools: ["bash", "read", "write"],
        permissions: {
          mode: "never",
          blocked_tools: ["destroy"],
          timeout: 60
        },
        system_prompt: "You are a test bot.",
        session: { timeout: 120 }
      }))

      config = Ask::AppServer::Config.new(config_path: config_path)
      assert_equal "gemini-2.0-flash", config.model
      assert_equal %w[bash read write], config.tools
      assert_equal :never, config.permission_mode
      assert_equal %w[destroy], config.blocked_tools
      assert_equal 60, config.permission_timeout
      assert_equal "You are a test bot.", config.system_prompt
      assert_equal 120, config.session_timeout
      assert_equal File.expand_path(config_path), config.source_path
    end
  end

  def test_partial_config_merges_with_defaults
    with_tempdir do |dir|
      config_path = File.join(dir, "partial.json")
      File.write(config_path, JSON.pretty_generate({
        model: "gpt-4o-mini"
      }))

      config = Ask::AppServer::Config.new(config_path: config_path)
      assert_equal "gpt-4o-mini", config.model
      assert_equal %w[bash read write edit glob grep], config.tools  # defaults
      assert_equal :on_request, config.permission_mode  # defaults
    end
  end

  def test_invalid_json_falls_back_to_defaults
    with_tempdir do |dir|
      config_path = File.join(dir, "bad.json")
      File.write(config_path, "this is not json")

      capture_io do
        config = Ask::AppServer::Config.new(config_path: config_path)
        assert_equal "gpt-4o", config.model  # defaults
        assert config.source_path, "should still report source path even with bad json"
      end
    end
  end

  def test_nonexistent_file_uses_defaults
    config = Ask::AppServer::Config.new(config_path: "/nonexistent/path/config.json")
    assert_equal "gpt-4o", config.model
    assert_nil config.source_path
  end

  def test_config_env_var_path
    with_tempdir do |dir|
      config_path = File.join(dir, "env_config.json")
      File.write(config_path, JSON.pretty_generate({ model: "o3-mini" }))

      original = ENV.delete("ASK_APP_SERVER_CONFIG")
      ENV["ASK_APP_SERVER_CONFIG"] = config_path
      begin
        config = Ask::AppServer::Config.new
        assert_equal "o3-mini", config.model
        assert_equal File.expand_path(config_path), config.source_path
      ensure
        if original
          ENV["ASK_APP_SERVER_CONFIG"] = original
        else
          ENV.delete("ASK_APP_SERVER_CONFIG")
        end
      end
    end
  end

  def test_env_var_overrides_config_file
    with_tempdir do |dir|
      config_path = File.join(dir, "override_test.json")
      File.write(config_path, JSON.pretty_generate({ model: "gemini-pro" }))

      original_model = ENV.delete("ASK_APP_SERVER_MODEL")
      ENV["ASK_APP_SERVER_MODEL"] = "o3-mini"
      begin
        config = Ask::AppServer::Config.new(config_path: config_path)
        assert_equal "o3-mini", config.model  # env wins
      ensure
        if original_model
          ENV["ASK_APP_SERVER_MODEL"] = original_model
        else
          ENV.delete("ASK_APP_SERVER_MODEL")
        end
      end
    end
  end

  def test_to_h_includes_all_keys
    config = Ask::AppServer::Config.new
    h = config.to_h
    assert h[:model]
    assert h[:tools]
    assert h[:permissions]
    assert h.key?(:system_prompt)
    assert h[:session]
    assert h[:source]
  end
end
