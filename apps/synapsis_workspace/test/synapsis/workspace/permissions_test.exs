defmodule Synapsis.Workspace.PermissionsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Permissions

  @agent_id "main"
  @other_agent_id "helper"
  @session_id "sess-001"
  @other_session_id "sess-999"

  describe "user role" do
    test "allows shared, agent, and session paths" do
      ctx = %{role: :user}

      assert Permissions.check(ctx, "/shared/notes/idea.md", :write) == :allowed
      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :write) == :allowed

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end
  end

  describe "global agent" do
    test "allows shared paths" do
      ctx = %{role: :global}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :allowed
    end

    test "allows delegated agent paths" do
      ctx = %{role: :global, agent_id: @agent_id}

      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :write) == :allowed

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end

    test "allows any agent path when not delegated" do
      ctx = %{role: :global, agent_id: nil}
      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :read) == :allowed
      assert Permissions.check(ctx, "/agents/#{@other_agent_id}/data.md", :write) == :allowed
    end

    test "denies other agent paths when delegated" do
      ctx = %{role: :global, agent_id: @agent_id}

      assert Permissions.check(ctx, "/agents/#{@other_agent_id}/plans/auth.md", :read) ==
               :denied
    end
  end

  describe "agent role" do
    test "allows own agent and session paths" do
      ctx = %{role: :agent, agent_id: @agent_id}

      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :write) == :allowed

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end

    test "denies other agent paths" do
      ctx = %{role: :agent, agent_id: @agent_id}

      assert Permissions.check(ctx, "/agents/#{@other_agent_id}/plans/auth.md", :read) ==
               :denied
    end

    test "allows shared read and denies shared write" do
      ctx = %{role: :agent, agent_id: @agent_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :denied
    end
  end

  describe "session role" do
    test "allows own session subtree" do
      ctx = %{role: :session, agent_id: @agent_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end

    test "allows own agent read and denies own agent write" do
      ctx = %{role: :session, agent_id: @agent_id, session_id: @session_id}
      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :read) == :allowed
      assert Permissions.check(ctx, "/agents/#{@agent_id}/plans/auth.md", :write) == :denied
    end

    test "allows same-agent other-session read and denies write" do
      ctx = %{role: :session, agent_id: @agent_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@other_session_id}/todo.md",
               :read
             ) == :allowed

      assert Permissions.check(
               ctx,
               "/agents/#{@agent_id}/sessions/#{@other_session_id}/todo.md",
               :write
             ) == :denied
    end

    test "denies other agent paths" do
      ctx = %{role: :session, agent_id: @agent_id, session_id: @session_id}

      assert Permissions.check(ctx, "/agents/#{@other_agent_id}/plans/auth.md", :read) ==
               :denied
    end

    test "allows shared read and denies shared write" do
      ctx = %{role: :session, agent_id: @agent_id, session_id: @session_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :denied
    end
  end

  describe "invalid paths" do
    test "user role still allowed for any path including root" do
      assert Permissions.check(%{role: :user}, "/", :read) == :allowed
    end

    test "non-user role denied for unrecognised path prefix" do
      assert Permissions.check(%{role: :agent, agent_id: @agent_id}, "/unknown/something", :read) ==
               :denied
    end
  end
end
