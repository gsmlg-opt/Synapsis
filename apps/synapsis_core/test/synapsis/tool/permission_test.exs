defmodule Synapsis.Tool.PermissionTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.{Permission, Permissions}

  describe "Permission.check/2 (backward compat)" do
    test "auto-approves read-only tools" do
      assert :approved = Permission.check("file_read", nil)
      assert :approved = Permission.check("grep", nil)
      assert :approved = Permission.check("glob", nil)
      assert :approved = Permission.check("diagnostics", nil)
      assert :approved = Permission.check("list_dir", nil)
    end

    test "requires approval for write tools" do
      assert :requires_approval = Permission.check("file_edit", nil)
      assert :requires_approval = Permission.check("file_write", nil)
      assert :requires_approval = Permission.check("fetch", nil)
      assert :requires_approval = Permission.check("file_move", nil)
    end

    test "requires approval for execute tools" do
      assert :requires_approval = Permission.check("bash", nil)
    end

    test "requires approval for destructive tools" do
      assert :requires_approval = Permission.check("file_delete", nil)
    end

    test "requires approval for MCP tools" do
      assert :requires_approval = Permission.check("mcp:server:tool", nil)
    end

    test "requires approval for unknown tools" do
      assert :requires_approval = Permission.check("unknown_tool", nil)
    end
  end

  describe "Permissions.level/1" do
    test "classifies read tools" do
      assert :read = Permissions.level("file_read")
      assert :read = Permissions.level("grep")
      assert :read = Permissions.level("glob")
      assert :read = Permissions.level("list_dir")
      assert :read = Permissions.level("diagnostics")
    end

    test "classifies write tools" do
      assert :write = Permissions.level("file_write")
      assert :write = Permissions.level("file_edit")
      assert :write = Permissions.level("file_move")
      assert :write = Permissions.level("fetch")
    end

    test "classifies execute tools" do
      assert :execute = Permissions.level("bash")
    end

    test "classifies destructive tools" do
      assert :destructive = Permissions.level("file_delete")
    end

    test "classifies MCP tools as write" do
      assert :write = Permissions.level("mcp:server:tool")
    end

    test "classifies LSP tools as read" do
      assert :read = Permissions.level("lsp_diagnostics")
      assert :read = Permissions.level("lsp_definition")
    end
  end

  describe "Permissions.allowed?/2" do
    test "allows read tools with read auto-approve" do
      assert Permissions.allowed?("file_read", %{auto_approve: [:read]})
    end

    test "denies write tools with only read auto-approve" do
      refute Permissions.allowed?("file_write", %{auto_approve: [:read]})
    end

    test "allows all with full auto-approve" do
      config = %{auto_approve: [:read, :write, :execute, :destructive]}
      assert Permissions.allowed?("file_read", config)
      assert Permissions.allowed?("bash", config)
      assert Permissions.allowed?("file_delete", config)
    end
  end
end
