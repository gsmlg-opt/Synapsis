defmodule Synapsis.Workspace.PermissionsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Permissions

  @project_id "proj-abc"
  @other_project_id "proj-xyz"
  @session_id "sess-001"
  @other_session_id "sess-999"

  # ---------------------------------------------------------------------------
  # User role
  # ---------------------------------------------------------------------------

  describe "user role" do
    test "allowed for shared path read" do
      ctx = %{role: :user}
      assert Permissions.check(ctx, "/shared/notes/idea.md", :read) == :allowed
    end

    test "allowed for shared path write" do
      ctx = %{role: :user}
      assert Permissions.check(ctx, "/shared/notes/idea.md", :write) == :allowed
    end

    test "allowed for project path read" do
      ctx = %{role: :user}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :read) == :allowed
    end

    test "allowed for project path write" do
      ctx = %{role: :user}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :write) == :allowed
    end

    test "allowed for session path read" do
      ctx = %{role: :user}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :allowed
    end

    test "allowed for session path write" do
      ctx = %{role: :user}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end
  end

  # ---------------------------------------------------------------------------
  # Global agent
  # ---------------------------------------------------------------------------

  describe "global agent — /shared/**" do
    test "allowed for shared path read" do
      ctx = %{role: :global}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
    end

    test "allowed for shared path write" do
      ctx = %{role: :global}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :allowed
    end
  end

  describe "global agent — project paths with delegation" do
    test "allowed for project path when project_id matches" do
      ctx = %{role: :global, project_id: @project_id}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :read) == :allowed
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :write) == :allowed
    end

    test "allowed for session path when project_id matches" do
      ctx = %{role: :global, project_id: @project_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :allowed

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end

    test "allowed for any project path when project_id is nil (undelegated)" do
      ctx = %{role: :global, project_id: nil}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :read) == :allowed
      assert Permissions.check(ctx, "/projects/#{@other_project_id}/data.md", :write) == :allowed
    end

    test "denied for project path when project_id does not match" do
      ctx = %{role: :global, project_id: @project_id}

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :read) ==
               :denied

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :write) ==
               :denied
    end

    test "denied for session path when project_id does not match" do
      ctx = %{role: :global, project_id: @project_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@other_project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :denied
    end
  end

  # ---------------------------------------------------------------------------
  # Project agent
  # ---------------------------------------------------------------------------

  describe "project agent — own project" do
    test "allowed for own project path read" do
      ctx = %{role: :project, project_id: @project_id}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :read) == :allowed
    end

    test "allowed for own project path write" do
      ctx = %{role: :project, project_id: @project_id}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :write) == :allowed
    end

    test "allowed for own project session subtree read" do
      ctx = %{role: :project, project_id: @project_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :allowed
    end

    test "allowed for own project session subtree write" do
      ctx = %{role: :project, project_id: @project_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end
  end

  describe "project agent — other project" do
    test "denied for other project path read" do
      ctx = %{role: :project, project_id: @project_id}

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :read) ==
               :denied
    end

    test "denied for other project path write" do
      ctx = %{role: :project, project_id: @project_id}

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :write) ==
               :denied
    end

    test "denied for other project session path" do
      ctx = %{role: :project, project_id: @project_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@other_project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :denied
    end
  end

  describe "project agent — /shared/**" do
    test "allowed for shared path read" do
      ctx = %{role: :project, project_id: @project_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
    end

    test "denied for shared path write" do
      ctx = %{role: :project, project_id: @project_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :denied
    end
  end

  # ---------------------------------------------------------------------------
  # Session agent
  # ---------------------------------------------------------------------------

  describe "session agent — own session subtree" do
    test "allowed for own session subtree read" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :allowed
    end

    test "allowed for own session subtree write" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@session_id}/todo.md",
               :write
             ) == :allowed
    end
  end

  describe "session agent — own project path (not own session)" do
    test "allowed for own project path read" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :read) == :allowed
    end

    test "denied for own project path write" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}
      assert Permissions.check(ctx, "/projects/#{@project_id}/plans/auth.md", :write) == :denied
    end

    test "denied for own project but different session write" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@other_session_id}/todo.md",
               :write
             ) == :denied
    end

    test "allowed for own project but different session read (read-only)" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@project_id}/sessions/#{@other_session_id}/todo.md",
               :read
             ) == :allowed
    end
  end

  describe "session agent — other project paths" do
    test "denied for other project path read" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :read) ==
               :denied
    end

    test "denied for other project path write" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(ctx, "/projects/#{@other_project_id}/plans/auth.md", :write) ==
               :denied
    end

    test "denied for other project session path" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}

      assert Permissions.check(
               ctx,
               "/projects/#{@other_project_id}/sessions/#{@session_id}/todo.md",
               :read
             ) == :denied
    end
  end

  describe "session agent — /shared/**" do
    test "allowed for shared path read" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :read) == :allowed
    end

    test "denied for shared path write" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}
      assert Permissions.check(ctx, "/shared/docs/readme.md", :write) == :denied
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid paths
  # ---------------------------------------------------------------------------

  describe "invalid paths" do
    test "user role still allowed for any path including root" do
      ctx = %{role: :user}
      # User short-circuits before path resolution
      assert Permissions.check(ctx, "/", :read) == :allowed
    end

    test "non-user role denied for unrecognised path prefix" do
      ctx = %{role: :project, project_id: @project_id}
      assert Permissions.check(ctx, "/unknown/something", :read) == :denied
    end

    test "global agent denied for unrecognised path prefix" do
      ctx = %{role: :global}
      assert Permissions.check(ctx, "/unknown/something", :write) == :denied
    end

    test "session agent denied for unrecognised path prefix" do
      ctx = %{role: :session, project_id: @project_id, session_id: @session_id}
      assert Permissions.check(ctx, "/bad/path", :read) == :denied
    end
  end
end
