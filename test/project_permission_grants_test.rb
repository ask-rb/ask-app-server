# frozen_string_literal: true

require_relative "test_helper"

class ProjectPermissionGrantsTest < Minitest::Test
  class State
    def initialize
      @values = {}
    end

    def get(key) = @values[key]
    def set(key, value, ttl: nil) = @values[key] = value
  end

  def test_grants_are_persisted_and_shared_by_workspace_identity
    state = State.new
    first = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")
    first.grant("bash")

    resumed = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1")

    assert resumed.granted?("bash")
    assert_equal({ version: 1, granted_tools: ["bash"] }, resumed.snapshot)
  end

  def test_grants_are_isolated_by_workspace_identity
    state = State.new
    Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-1").grant("bash")
    other = Ask::AppServer::ProjectPermissionGrants.new(state: state, project_id: "workspace-2")

    refute other.granted?("bash")
  end

  def test_revoke_removes_only_the_selected_tool
    grants = Ask::AppServer::ProjectPermissionGrants.new(state: State.new, project_id: "workspace-1")
    grants.grant("bash")
    grants.grant("write")

    grants.revoke("bash")

    refute grants.granted?("bash")
    assert grants.granted?("write")
  end

  def test_invalid_project_identity_is_rejected
    assert_raises(ArgumentError) do
      Ask::AppServer::ProjectPermissionGrants.new(state: State.new, project_id: " ")
    end
  end
end
