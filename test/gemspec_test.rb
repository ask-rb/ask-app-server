# frozen_string_literal: true

require_relative "test_helper"

class GemspecTest < Minitest::Test
  def test_gemspec_is_valid
    spec = Gem::Specification.load("ask-app-server.gemspec")
    assert spec, "gemspec should load"
    assert_equal "ask-app-server", spec.name
    assert_equal Ask::AppServer::VERSION, spec.version.to_s
    assert spec.summary, "should have a summary"
    assert spec.description, "should have a description"
    assert spec.homepage, "should have a homepage"
    assert_equal "MIT", spec.license
    assert spec.files.any? { |f| f.start_with?("lib/") }, "should include lib files"
    assert_includes spec.executables, "ask-app-server", "should have ask-app-server executable"
    assert_includes spec.files, "LICENSE", "should include LICENSE"
  end

  def test_version_is_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Ask::AppServer::VERSION, "version is defined and semver")
  end

  def test_error_classes_exist
    assert Ask::AppServer::Error
    assert Ask::AppServer::ProtocolError
    assert Ask::AppServer::SessionNotFound
    assert Ask::AppServer::SessionAlreadyExists
    assert Ask::AppServer::InteractionNotFound
    assert Ask::AppServer::PlanNotFound
    assert Ask::AppServer::InvalidRequest
    assert Ask::AppServer::TimeoutError
  end

  def test_depends_on_session_protocol
    spec = Gem::Specification.load("ask-app-server.gemspec")
    assert spec.dependencies.any? { |d| d.name == "ask-session-protocol" }
  end

  def test_depends_on_ask_session
    spec = Gem::Specification.load("ask-app-server.gemspec")
    dep = spec.dependencies.find { |d| d.name == "ask-session" }
    assert dep, "should depend on ask-session (durable event source)"

    resolved_version =
      if defined?(Bundler)
        Bundler.definition.specs.find { |s| s.name == "ask-session" }&.version
      end
    resolved_version ||= Gem.loaded_specs["ask-session"]&.version

    assert resolved_version, "resolved ask-session version should be available via Bundler or Gem.loaded_specs"
    assert dep.requirement.satisfied_by?(resolved_version),
           "gemspec ask-session requirement (#{dep.requirement}) should accept resolved version #{resolved_version}"
  end
end
