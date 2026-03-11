defmodule Synapsis.Tool.BuiltinTest do
  use ExUnit.Case

  alias Synapsis.Tool.Builtin
  alias Synapsis.Tool.Registry

  @all_expected_tools [
    "file_read",
    "file_edit",
    "file_write",
    "bash",
    "grep",
    "glob",
    "fetch",
    "diagnostics",
    "list_dir",
    "file_delete",
    "file_move",
    "multi_edit",
    "todo_write",
    "todo_read",
    "enter_plan_mode",
    "exit_plan_mode",
    "web_search",
    "ask_user",
    "task",
    "skill",
    "sleep",
    "send_message",
    "tool_search",
    "teammate",
    "team_delete",
    "notebook_edit",
    "notebook_read",
    "computer"
  ]

  @disabled_tool_names ["notebook_edit", "notebook_read", "computer", "task"]
  @enabled_tool_names @all_expected_tools -- @disabled_tool_names

  @expected_timeouts %{
    "file_read" => 5_000,
    "file_edit" => 10_000,
    "file_write" => 10_000,
    "bash" => 30_000,
    "grep" => 10_000,
    "glob" => 5_000,
    "fetch" => 15_000,
    "diagnostics" => 10_000,
    "list_dir" => 5_000,
    "file_delete" => 5_000,
    "file_move" => 5_000,
    "multi_edit" => 15_000,
    "web_search" => 15_000,
    "ask_user" => 300_000,
    "task" => 600_000,
    "sleep" => 600_000
  }

  # Tools are registered at application startup by Builtin.register_all/0.
  # We do NOT unregister them — we verify the app-startup state.

  describe "register_all/0 total tool count" do
    test "Registry.list/0 returns exactly 28 tools from builtin set" do
      all_tools = Registry.list()
      all_names = Enum.map(all_tools, & &1.name) |> MapSet.new()

      for name <- @all_expected_tools do
        assert MapSet.member?(all_names, name),
               "Expected tool #{inspect(name)} to be in Registry.list/0"
      end

      builtin_tools = Enum.filter(all_tools, &(&1.name in @all_expected_tools))
      assert length(builtin_tools) == 28
    end
  end

  describe "enabled tools" do
    test "25 tools are enabled" do
      enabled_count =
        @all_expected_tools
        |> Enum.count(fn name ->
          {:ok, {:module, mod, _opts}} = Registry.lookup(name)
          not (function_exported?(mod, :enabled?, 0) and not mod.enabled?())
        end)

      assert enabled_count == 24
    end

    test "all expected enabled tools respond to enabled? as true or default" do
      for name <- @enabled_tool_names do
        {:ok, {:module, mod, _opts}} = Registry.lookup(name)

        enabled =
          if function_exported?(mod, :enabled?, 0) do
            mod.enabled?()
          else
            true
          end

        assert enabled,
               "Expected tool #{inspect(name)} to be enabled, but enabled?/0 returned false"
      end
    end
  end

  describe "disabled tools" do
    test "exactly 4 tools are disabled: notebook_edit, notebook_read, computer, task" do
      disabled =
        @all_expected_tools
        |> Enum.filter(fn name ->
          {:ok, {:module, mod, _opts}} = Registry.lookup(name)
          function_exported?(mod, :enabled?, 0) and not mod.enabled?()
        end)

      assert Enum.sort(disabled) == Enum.sort(@disabled_tool_names)
      assert length(disabled) == 4
    end
  end

  describe "specific tool names are present" do
    @must_have_tools [
      "file_read",
      "bash",
      "grep",
      "multi_edit",
      "todo_write",
      "web_search",
      "ask_user",
      "task",
      "tool_search",
      "teammate",
      "computer"
    ]

    test "critical tools are registered" do
      for name <- @must_have_tools do
        assert {:ok, {:module, _mod, _opts}} = Registry.lookup(name),
               "Expected critical tool #{inspect(name)} to be registered"
      end
    end
  end

  describe "tool metadata" do
    test "all tools are lookupable via Registry.lookup/1" do
      for name <- @all_expected_tools do
        assert {:ok, {:module, _module, _opts}} = Registry.lookup(name),
               "Expected #{inspect(name)} to be lookupable"
      end
    end

    test "each registered tool has a description" do
      for name <- @all_expected_tools do
        {:ok, {:module, module, opts}} = Registry.lookup(name)

        assert is_binary(opts[:description]),
               "Tool #{name}: expected description to be a string"

        assert opts[:description] == module.description(),
               "Tool #{name}: description in opts should match module.description()"
      end
    end

    test "each registered tool has parameters" do
      for name <- @all_expected_tools do
        {:ok, {:module, module, opts}} = Registry.lookup(name)

        assert is_map(opts[:parameters]),
               "Tool #{name}: expected parameters to be a map"

        assert opts[:parameters] == module.parameters(),
               "Tool #{name}: parameters in opts should match module.parameters()"
      end
    end

    test "tools with known timeouts have correct values" do
      for {name, expected_timeout} <- @expected_timeouts do
        {:ok, {:module, _module, opts}} = Registry.lookup(name)

        assert opts[:timeout] == expected_timeout,
               "Tool #{name}: expected timeout #{expected_timeout}, got #{inspect(opts[:timeout])}"
      end
    end
  end

  describe "register_all/0 idempotency" do
    test "calling register_all/0 again does not crash or duplicate" do
      assert :ok = Builtin.register_all()

      # All tools should still be lookupable
      for name <- @all_expected_tools do
        assert {:ok, {:module, _module, _opts}} = Registry.lookup(name),
               "Tool #{name} should still be registered after re-registration"
      end

      # Count should still be 28
      all_tools = Registry.list()
      builtin_tools = Enum.filter(all_tools, &(&1.name in @all_expected_tools))
      assert length(builtin_tools) == 28
    end
  end
end
