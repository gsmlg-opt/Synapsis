defmodule Synapsis.Tool.BuiltinTest do
  use ExUnit.Case

  alias Synapsis.Tool.Builtin
  alias Synapsis.Tool.Registry

  @expected_tools %{
    "file_read" => %{module: Synapsis.Tool.FileRead, timeout: 5_000},
    "file_edit" => %{module: Synapsis.Tool.FileEdit, timeout: 10_000},
    "file_write" => %{module: Synapsis.Tool.FileWrite, timeout: 10_000},
    "bash" => %{module: Synapsis.Tool.Bash, timeout: 30_000},
    "grep" => %{module: Synapsis.Tool.Grep, timeout: 10_000},
    "glob" => %{module: Synapsis.Tool.Glob, timeout: 5_000},
    "fetch" => %{module: Synapsis.Tool.Fetch, timeout: 15_000},
    "diagnostics" => %{module: Synapsis.Tool.Diagnostics, timeout: 10_000},
    "list_dir" => %{module: Synapsis.Tool.ListDir, timeout: 5_000},
    "file_delete" => %{module: Synapsis.Tool.FileDelete, timeout: 5_000},
    "file_move" => %{module: Synapsis.Tool.FileMove, timeout: 5_000}
  }

  @tool_names Map.keys(@expected_tools)

  setup do
    on_exit(fn ->
      for name <- @tool_names do
        Registry.unregister(name)
      end
    end)

    # Ensure a clean slate: unregister any leftover entries from prior tests
    for name <- @tool_names, do: Registry.unregister(name)

    :ok
  end

  describe "register_all/0" do
    test "returns :ok" do
      assert :ok = Builtin.register_all()
    end

    test "registers all 11 built-in tools" do
      Builtin.register_all()

      registered = Registry.list()
      registered_names = Enum.map(registered, & &1.name) |> MapSet.new()

      for name <- @tool_names do
        assert MapSet.member?(registered_names, name),
               "Expected tool #{inspect(name)} to be registered"
      end

      # Verify count: at least 11 tools from the builtin set are present
      builtin_registered = Enum.filter(registered, &(&1.name in @tool_names))
      assert length(builtin_registered) == 11
    end

    test "all tool names are lookupable via Registry" do
      Builtin.register_all()

      for name <- @tool_names do
        assert {:ok, {:module, _module, _opts}} = Registry.lookup(name),
               "Expected #{inspect(name)} to be lookupable"
      end
    end

    test "each registered tool has correct module" do
      Builtin.register_all()

      for {name, %{module: expected_module}} <- @expected_tools do
        {:ok, {:module, module, _opts}} = Registry.lookup(name)

        assert module == expected_module,
               "Tool #{name}: expected module #{expected_module}, got #{module}"
      end
    end

    test "each registered tool has correct timeout" do
      Builtin.register_all()

      for {name, %{timeout: expected_timeout}} <- @expected_tools do
        {:ok, {:module, _module, opts}} = Registry.lookup(name)

        assert opts[:timeout] == expected_timeout,
               "Tool #{name}: expected timeout #{expected_timeout}, got #{inspect(opts[:timeout])}"
      end
    end

    test "each registered tool has a description" do
      Builtin.register_all()

      for name <- @tool_names do
        {:ok, {:module, module, opts}} = Registry.lookup(name)

        assert is_binary(opts[:description]),
               "Tool #{name}: expected description to be a string"

        assert opts[:description] == module.description(),
               "Tool #{name}: description in opts should match module.description()"
      end
    end

    test "each registered tool has parameters" do
      Builtin.register_all()

      for name <- @tool_names do
        {:ok, {:module, module, opts}} = Registry.lookup(name)

        assert is_map(opts[:parameters]),
               "Tool #{name}: expected parameters to be a map"

        assert opts[:parameters] == module.parameters(),
               "Tool #{name}: parameters in opts should match module.parameters()"
      end
    end

    test "is idempotent - calling twice does not crash" do
      assert :ok = Builtin.register_all()
      assert :ok = Builtin.register_all()

      # All tools should still be lookupable after double registration
      for name <- @tool_names do
        assert {:ok, {:module, _module, _opts}} = Registry.lookup(name),
               "Tool #{name} should still be registered after second call"
      end
    end
  end
end
