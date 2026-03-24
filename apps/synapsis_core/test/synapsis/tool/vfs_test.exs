defmodule Synapsis.Tool.VFSTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.VFS

  describe "virtual?/1" do
    test "returns true for @synapsis/ paths" do
      assert VFS.virtual?("@synapsis/projects/myapp/plans/auth.md")
      assert VFS.virtual?("@synapsis/shared/notes/ideas.md")
      assert VFS.virtual?("@synapsis/global/soul.md")
    end

    test "returns false for regular paths" do
      refute VFS.virtual?("/home/user/file.txt")
      refute VFS.virtual?("relative/path.ex")
      refute VFS.virtual?(".")
      refute VFS.virtual?(nil)
    end

    test "is case-sensitive" do
      refute VFS.virtual?("@Synapsis/projects/test")
      refute VFS.virtual?("@SYNAPSIS/projects/test")
    end
  end

  describe "strip_prefix/1" do
    test "strips @synapsis/ and adds leading slash" do
      assert VFS.strip_prefix("@synapsis/projects/myapp/plans/auth.md") ==
               "/projects/myapp/plans/auth.md"
    end

    test "returns path as-is when no prefix" do
      assert VFS.strip_prefix("/home/user/file.txt") == "/home/user/file.txt"
    end
  end

  describe "add_prefix/1" do
    test "adds @synapsis/ prefix to workspace path" do
      assert VFS.add_prefix("/projects/myapp/plans/auth.md") ==
               "@synapsis/projects/myapp/plans/auth.md"
    end

    test "adds prefix to path without leading slash" do
      assert VFS.add_prefix("projects/test") == "@synapsis/projects/test"
    end
  end

  describe "move/2 cross-boundary rejection" do
    test "rejects move from workspace to real filesystem" do
      assert {:error, msg} = VFS.move("@synapsis/projects/test/file.md", "/tmp/file.md")
      assert msg =~ "Cannot move from workspace to real filesystem"
    end

    test "rejects move from real filesystem to workspace" do
      assert {:error, msg} = VFS.move("/tmp/file.md", "@synapsis/projects/test/file.md")
      assert msg =~ "Cannot move from real filesystem to workspace"
    end
  end

  describe "glob_to_like/1 (via WorkspaceDocuments)" do
    test "converts glob patterns to SQL LIKE" do
      assert Synapsis.WorkspaceDocuments.glob_to_like("**/*.md") == "%/%.md"
      assert Synapsis.WorkspaceDocuments.glob_to_like("*.ex") == "%.ex"
      # _ gets escaped to \_, then ? becomes _
      assert Synapsis.WorkspaceDocuments.glob_to_like("test_?") == "test\\__"
      assert Synapsis.WorkspaceDocuments.glob_to_like("a?b") == "a_b"
      assert Synapsis.WorkspaceDocuments.glob_to_like("file%name") == "file\\%name"
    end
  end
end
