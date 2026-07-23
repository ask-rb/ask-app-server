# frozen_string_literal: true

require_relative "test_helper"

class GemspecTest < Minitest::Test
  def test_gemspec_is_valid
    spec = Gem::Specification.load("ask-app-server.gemspec")
    assert spec, "gemspec should load"
    assert_equal "ask-app-server", spec.name
    assert_equal "0.1.0", spec.version.to_s
    assert spec.summary, "should have a summary"
    assert spec.description, "should have a description"
    assert spec.homepage, "should have a homepage"
    assert_equal "MIT", spec.license
    assert spec.files.any? { |f| f.start_with?("lib/") }, "should include lib files"
    assert_includes spec.executables, "ask-app-server", "should have ask-app-server executable"
    assert_includes spec.files, "LICENSE", "should include LICENSE"
  end

  def test_version_is_defined
    assert_equal "0.1.0", Ask::AppServer::VERSION
  end

  def test_error_classes_exist
    assert Ask::AppServer::Error
    assert Ask::AppServer::ProtocolError
    assert Ask::AppServer::SessionNotFound
    assert Ask::AppServer::SessionAlreadyExists
    assert Ask::AppServer::InvalidRequest
    assert Ask::AppServer::TimeoutError
  end
end
