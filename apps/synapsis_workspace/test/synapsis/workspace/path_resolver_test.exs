defmodule Synapsis.Workspace.PathResolverTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.PathResolver

  describe "resolve/1" do
    test "resolves global shared path" do
      assert {:ok, resolved} = PathResolver.resolve("/shared/notes/idea.md")
      assert resolved.scope == :global
      assert resolved.project_id == nil
      assert resolved.session_id == nil
      assert resolved.default_visibility == :global_shared
      assert resolved.segments == ["notes", "idea.md"]
    end

    test "resolves project path" do
      assert {:ok, resolved} = PathResolver.resolve("/projects/abc123/plans/auth.md")
      assert resolved.scope == :project
      assert resolved.project_id == "abc123"
      assert resolved.session_id == nil
      assert resolved.default_visibility == :project_shared
      assert resolved.segments == ["plans", "auth.md"]
    end

    test "resolves session path" do
      assert {:ok, resolved} =
               PathResolver.resolve("/projects/abc/sessions/sess1/todo.md")

      assert resolved.scope == :session
      assert resolved.project_id == "abc"
      assert resolved.session_id == "sess1"
      assert resolved.default_visibility == :private
      assert resolved.segments == ["todo.md"]
    end

    test "resolves session scratch path with scratch lifecycle" do
      assert {:ok, resolved} =
               PathResolver.resolve("/projects/abc/sessions/sess1/scratch/draft.md")

      assert resolved.default_lifecycle == :scratch
    end

    test "returns error for empty path" do
      assert {:error, "empty path"} = PathResolver.resolve("/")
    end

    test "returns error for invalid path prefix" do
      assert {:error, _} = PathResolver.resolve("/unknown/path")
    end
  end

  describe "normalize_path/1" do
    test "collapses double slashes" do
      assert PathResolver.normalize_path("//shared//notes//") == "/shared/notes"
    end

    test "ensures leading slash" do
      assert PathResolver.normalize_path("shared/notes") == "/shared/notes"
    end

    test "removes trailing slash" do
      assert PathResolver.normalize_path("/shared/notes/") == "/shared/notes"
    end
  end

  describe "derive_kind/1" do
    test "derives attachment kind" do
      assert PathResolver.derive_kind(["attachments", "user", "file.pdf"]) == :attachment
    end

    test "derives handoff kind" do
      assert PathResolver.derive_kind(["handoffs", "handoff-01.json"]) == :handoff
    end

    test "derives session_scratch kind" do
      assert PathResolver.derive_kind(["scratch", "draft.md"]) == :session_scratch
    end

    test "defaults to document" do
      assert PathResolver.derive_kind(["plans", "auth.md"]) == :document
    end
  end

  describe "parent/1" do
    test "returns parent directory" do
      assert PathResolver.parent("/shared/notes/idea.md") == "/shared/notes"
    end

    test "returns root for top-level" do
      assert PathResolver.parent("/shared") == "/"
    end
  end
end
