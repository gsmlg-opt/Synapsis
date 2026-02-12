defmodule Synapsis.Tool.PermissionTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Permission

  test "auto-approves read-only tools" do
    assert :approved = Permission.check("file_read", nil)
    assert :approved = Permission.check("grep", nil)
    assert :approved = Permission.check("glob", nil)
    assert :approved = Permission.check("diagnostics", nil)
  end

  test "requires approval for write tools" do
    assert :requires_approval = Permission.check("bash", nil)
    assert :requires_approval = Permission.check("file_edit", nil)
    assert :requires_approval = Permission.check("file_write", nil)
    assert :requires_approval = Permission.check("fetch", nil)
  end

  test "requires approval for MCP tools" do
    assert :requires_approval = Permission.check("mcp:server:tool", nil)
  end

  test "requires approval for unknown tools" do
    assert :requires_approval = Permission.check("unknown_tool", nil)
  end
end
