defmodule Synapsis.ToolsetTest do
  use Synapsis.DataCase

  alias Synapsis.{Toolset, Toolsets}

  describe "changeset/2" do
    test "accepts named toolsets with built-in and MCP tools" do
      changeset =
        Toolset.changeset(%Toolset{}, %{
          name: "code-tools",
          description: "Coding tools",
          tool_names: ["file_read", "mcp:filesystem:read_file"]
        })

      assert changeset.valid?
      assert get_field(changeset, :tool_names) == ["file_read", "mcp:filesystem:read_file"]
    end

    test "requires name" do
      changeset = Toolset.changeset(%Toolset{}, %{tool_names: ["file_read"]})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "toolsets context" do
    test "creates, updates, lists, and deletes toolsets" do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "readers",
          description: "Read-only tools",
          tool_names: ["file_read", "grep"]
        })

      assert toolset.name == "readers"
      assert Toolsets.get(toolset.id).id == toolset.id

      {:ok, updated} = Toolsets.update(toolset, %{tool_names: ["file_read"]})
      assert updated.tool_names == ["file_read"]
      assert Enum.map(Toolsets.list(), & &1.name) == ["readers"]

      assert {:ok, _} = Toolsets.delete(updated)
      assert Toolsets.get(toolset.id) == nil
    end

    test "does not delete built-in toolsets" do
      {:ok, toolset} = Toolsets.create(%{name: "builtin", is_builtin: true})
      assert {:error, :protected} = Toolsets.delete(toolset)
      assert Toolsets.get(toolset.id)
    end
  end
end
