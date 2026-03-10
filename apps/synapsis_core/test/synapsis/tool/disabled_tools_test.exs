defmodule Synapsis.Tool.DisabledToolsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.NotebookRead
  alias Synapsis.Tool.NotebookEdit
  alias Synapsis.Tool.Computer

  @disabled_tools [
    {NotebookRead, "notebook_read", :read, :notebook, "Notebook tools are not enabled"},
    {NotebookEdit, "notebook_edit", :write, :notebook, "Notebook tools are not enabled"},
    {Computer, "computer", :execute, :computer, "Computer use is not enabled"}
  ]

  for {mod, tool_name, permission, category, error_msg} <- @disabled_tools do
    describe "#{tool_name}" do
      test "enabled?/0 returns false" do
        assert unquote(mod).enabled?() == false
      end

      test "name/0 returns #{tool_name}" do
        assert unquote(mod).name() == unquote(tool_name)
      end

      test "description/0 returns a non-empty string" do
        desc = unquote(mod).description()
        assert is_binary(desc)
        assert String.length(desc) > 0
      end

      test "parameters/0 returns a valid JSON schema object" do
        params = unquote(mod).parameters()
        assert is_map(params)
        assert params["type"] == "object"
        assert is_map(params["properties"])
        assert is_list(params["required"])
      end

      test "permission_level/0 returns #{permission}" do
        assert unquote(mod).permission_level() == unquote(permission)
      end

      test "category/0 returns #{category}" do
        assert unquote(mod).category() == unquote(category)
      end

      test "execute/2 returns error" do
        assert {:error, unquote(error_msg)} ==
                 unquote(mod).execute(%{}, %{})
      end
    end
  end

  describe "NotebookEdit side_effects" do
    test "declares :file_changed side effect" do
      assert :file_changed in NotebookEdit.side_effects()
    end
  end

  describe "NotebookRead side_effects" do
    test "has no side effects" do
      assert NotebookRead.side_effects() == []
    end
  end

  describe "Computer side_effects" do
    test "has no side effects" do
      assert Computer.side_effects() == []
    end
  end
end
