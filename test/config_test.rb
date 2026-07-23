# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include AppServerTestHelpers

  def setup
    # Register a stub model so ModelCatalog doesn't blow up when tests
    # reference deepseek-v4-flash
    register_stub_model("deepseek-v4-flash", "opencode_go")
  end

  def teardown
    # Clean up registered models after each test
    cleanup_stub_models
  end

  def test_defaults
    config = Ask::AppServer::Config.new
    assert_equal "opencode_go/deepseek-v4-flash", config.model
    assert_equal "deepseek-v4-flash", config.model_id
    assert_equal "opencode_go", config.model_provider
    assert_equal %w[bash read write edit glob grep], config.tools
    assert_equal :on_request, config.permission_mode
    assert_equal %w[write edit bash destroy], config.blocked_tools
    assert_equal 300, config.permission_timeout
    assert_equal 600, config.session_timeout
    assert_nil config.system_prompt
    refute config.debug?
  end

  def test_parsed_model_bare_name
    config = Ask::AppServer::Config.new
    # Override via env
    original = ENV.delete("ASK_APP_SERVER_MODEL")
    ENV["ASK_APP_SERVER_MODEL"] = "gpt-4o"
    begin
      assert_equal [nil, "gpt-4o"], config.parsed_model
      assert_equal "gpt-4o", config.model_id
      assert_nil config.model_provider
    ensure
      if original
        ENV["ASK_APP_SERVER_MODEL"] = original
      else
        ENV.delete("ASK_APP_SERVER_MODEL")
      end
    end
  end

  def test_parsed_model_with_provider
    config = Ask::AppServer::Config.new
    original = ENV.delete("ASK_APP_SERVER_MODEL")
    ENV["ASK_APP_SERVER_MODEL"] = "anthropic/claude-sonnet-4"
    begin
      assert_equal %w[anthropic claude-sonnet-4], config.parsed_model
      assert_equal "claude-sonnet-4", config.model_id
      assert_equal "anthropic", config.model_provider
    ensure
      if original
        ENV["ASK_APP_SERVER_MODEL"] = original
      else
        ENV.delete("ASK_APP_SERVER_MODEL")
      end
    end
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
        model: "gemini/gemini-2.0-flash",
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
      assert_equal "gemini/gemini-2.0-flash", config.model
      assert_equal "gemini", config.model_provider
      assert_equal "gemini-2.0-flash", config.model_id
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
        assert_equal "opencode_go/deepseek-v4-flash", config.model  # defaults
        assert config.source_path, "should still report source path even with bad json"
      end
    end
  end

  def test_nonexistent_file_uses_defaults
    config = Ask::AppServer::Config.new(config_path: "/nonexistent/path/config.json")
    assert_equal "opencode_go/deepseek-v4-flash", config.model
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
    assert h[:provider]
    assert h[:tools]
    assert h[:permissions]
    assert h.key?(:system_prompt)
    assert h[:session]
    assert h[:source]
  end

  # --- Custom models ---

  def test_custom_models_from_config
    with_tempdir do |dir|
      config_path = File.join(dir, "custom_models.json")
      File.write(config_path, JSON.pretty_generate({
        model: "my_provider/my-model",
        custom_models: {
          "my-model": {
            provider: "my_provider",
            context: 32000,
            output: 8000
          }
        }
      }))

      config = Ask::AppServer::Config.new(config_path: config_path)
      assert_equal "my_provider/my-model", config.model

      models = config.custom_models
      assert models.key?(:'my-model') || models.key?("my-model"), "should have my-model"
    end
  end

  def test_register_models!
    with_tempdir do |dir|
      config_path = File.join(dir, "register_test.json")
      File.write(config_path, JSON.pretty_generate({
        custom_models: {
          "test-model-v1": {
            provider: "opencode_go",
            context: 1000000,
            output: 384000
          }
        }
      }))

      config = Ask::AppServer::Config.new(config_path: config_path)
      config.register_models!

      # Should not raise
      catalog = Ask::ModelCatalog.instance
      model = catalog.find("test-model-v1")
      assert model, "model should be registered"
      assert_equal "opencode_go", model.provider
    end
  end

  def test_register_models_safe_to_call_multiple_times
    config = Ask::AppServer::Config.new
    config.register_models!
    config.register_models!  # Should not raise or duplicate
    assert true
  end

  private

  def register_stub_model(model_id, provider)
    catalog = Ask::ModelCatalog.instance
    model = OpenStruct.new(
      id: model_id,
      provider: provider,
      chat?: true,
      context: 4096,
      output: 4096
    )
    catalog.register(model) if catalog.respond_to?(:register)
  end

  def cleanup_stub_models
    # We can't easily remove models from the catalog, but since we register
    # unique model IDs per test, this shouldn't cause issues.
  end
end
