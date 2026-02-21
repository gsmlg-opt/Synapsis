defmodule Synapsis.Tool.RegistryTest do
  use ExUnit.Case

  alias Synapsis.Tool.Registry

  # The Registry GenServer is started by the application supervisor.
  # We operate directly on the ETS table since it's public.

  setup do
    # Clean up any test-specific entries after each test
    on_exit(fn ->
      Registry.unregister("test_tool")
      Registry.unregister("test_tool_2")
      Registry.unregister("test_process_tool")
    end)

    :ok
  end

  defmodule FakeTool do
    def description, do: "A fake tool for testing"
    def parameters, do: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
    def execute(_input, _ctx), do: {:ok, "done"}
  end

  describe "register_module/3" do
    test "registers a module-based tool" do
      assert :ok = Registry.register_module("test_tool", FakeTool)
      assert {:ok, {:module, FakeTool, []}} = Registry.lookup("test_tool")
    end

    test "registers with opts" do
      assert :ok = Registry.register_module("test_tool", FakeTool, timeout: 5_000)
      assert {:ok, {:module, FakeTool, [timeout: 5_000]}} = Registry.lookup("test_tool")
    end
  end

  describe "register_process/3" do
    test "registers a process-based tool" do
      pid = self()
      assert :ok = Registry.register_process("test_process_tool", pid, description: "proc tool")

      assert {:ok, {:process, ^pid, [description: "proc tool"]}} =
               Registry.lookup("test_process_tool")
    end
  end

  describe "register/1" do
    test "registers from a map" do
      assert :ok =
               Registry.register(%{
                 name: "test_tool",
                 module: FakeTool,
                 timeout: 10_000
               })

      assert {:ok, {:module, FakeTool, opts}} = Registry.lookup("test_tool")
      assert opts[:timeout] == 10_000
      assert opts[:description] == "A fake tool for testing"
    end
  end

  describe "lookup/1" do
    test "returns error for unregistered tool" do
      assert {:error, :not_found} = Registry.lookup("nonexistent_tool_xyz")
    end
  end

  describe "get/1" do
    test "returns map format for module tool" do
      Registry.register_module("test_tool", FakeTool, timeout: 5_000)

      assert {:ok, tool} = Registry.get("test_tool")
      assert tool.name == "test_tool"
      assert tool.module == FakeTool
      assert tool.description == "A fake tool for testing"
      assert tool.timeout == 5_000
      assert tool.parameters == FakeTool.parameters()
    end

    test "returns map format for process tool" do
      pid = self()

      Registry.register_process("test_process_tool", pid,
        description: "proc",
        parameters: %{"a" => 1}
      )

      assert {:ok, tool} = Registry.get("test_process_tool")
      assert tool.name == "test_process_tool"
      assert tool.process == pid
      assert tool.description == "proc"
      assert tool.parameters == %{"a" => 1}
    end

    test "returns error for missing tool" do
      assert {:error, :not_found} = Registry.get("nonexistent_tool_xyz")
    end
  end

  describe "list/0" do
    test "includes registered module tools" do
      Registry.register_module("test_tool", FakeTool)
      tools = Registry.list()
      tool = Enum.find(tools, &(&1.name == "test_tool"))
      assert tool
      assert tool.module == FakeTool
    end

    test "includes registered process tools" do
      pid = self()
      Registry.register_process("test_process_tool", pid, description: "p")
      tools = Registry.list()
      tool = Enum.find(tools, &(&1.name == "test_process_tool"))
      assert tool
      assert tool.process == pid
    end
  end

  describe "list_for_llm/0" do
    test "returns name, description, parameters for module tools" do
      Registry.register_module("test_tool", FakeTool)
      tools = Registry.list_for_llm()
      tool = Enum.find(tools, &(&1.name == "test_tool"))
      assert tool
      assert tool.description == "A fake tool for testing"
      assert tool.parameters == FakeTool.parameters()
      refute Map.has_key?(tool, :module)
    end

    test "returns name, description, parameters for process tools" do
      pid = self()

      Registry.register_process("test_process_tool", pid,
        description: "A process tool",
        parameters: %{"type" => "object"}
      )

      tools = Registry.list_for_llm()
      tool = Enum.find(tools, &(&1.name == "test_process_tool"))
      assert tool
      assert tool.description == "A process tool"
      assert tool.parameters == %{"type" => "object"}
      refute Map.has_key?(tool, :process)
    end
  end

  describe "unregister/1" do
    test "removes a registered tool" do
      Registry.register_module("test_tool", FakeTool)
      assert {:ok, _} = Registry.lookup("test_tool")

      assert :ok = Registry.unregister("test_tool")
      assert {:error, :not_found} = Registry.lookup("test_tool")
    end

    test "is idempotent for missing tools" do
      assert :ok = Registry.unregister("nonexistent_tool_xyz")
    end
  end
end
