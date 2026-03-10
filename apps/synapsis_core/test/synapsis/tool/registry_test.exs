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
      assert {:ok, {:module, FakeTool, opts}} = Registry.lookup("test_tool")
      # Enriched opts include metadata resolved from module callbacks
      assert opts[:category] == :filesystem
      assert opts[:permission_level] == :read
      assert opts[:enabled] == true
      assert opts[:deferred] == false
    end

    test "registers with opts" do
      assert :ok = Registry.register_module("test_tool", FakeTool, timeout: 5_000)
      assert {:ok, {:module, FakeTool, opts}} = Registry.lookup("test_tool")
      assert opts[:timeout] == 5_000
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

  # --- Extension tests (T031) ---

  defmodule WriteTool do
    use Synapsis.Tool

    @impl true
    def name, do: "write_tool"
    @impl true
    def description, do: "Writes things"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "written"}
    @impl true
    def permission_level, do: :write
    @impl true
    def category, do: :filesystem
  end

  defmodule ExecuteTool do
    use Synapsis.Tool

    @impl true
    def name, do: "exec_tool"
    @impl true
    def description, do: "Executes things"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "executed"}
    @impl true
    def permission_level, do: :execute
    @impl true
    def category, do: :execution
  end

  defmodule DisabledTool do
    use Synapsis.Tool

    @impl true
    def name, do: "disabled_tool"
    @impl true
    def description, do: "Disabled"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "nope"}
    @impl true
    def enabled?, do: false
  end

  defmodule SearchTool do
    use Synapsis.Tool

    @impl true
    def name, do: "search_tool"
    @impl true
    def description, do: "Searches"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_input, _ctx), do: {:ok, "found"}
    @impl true
    def category, do: :search
  end

  describe "list_for_llm/1 filtering" do
    setup do
      Registry.register_module("write_tool", WriteTool)
      Registry.register_module("exec_tool", ExecuteTool)
      Registry.register_module("disabled_tool", DisabledTool)
      Registry.register_module("search_tool", SearchTool)

      on_exit(fn ->
        Registry.unregister("write_tool")
        Registry.unregister("exec_tool")
        Registry.unregister("disabled_tool")
        Registry.unregister("search_tool")
        Registry.unregister("deferred_tool")
      end)

      :ok
    end

    test "plan mode excludes write/execute/destructive tools" do
      tools = Registry.list_for_llm(agent_mode: :plan)
      names = Enum.map(tools, & &1.name)
      refute "write_tool" in names
      refute "exec_tool" in names
      assert "search_tool" in names
    end

    test "build mode includes all permission levels" do
      tools = Registry.list_for_llm(agent_mode: :build)
      names = Enum.map(tools, & &1.name)
      assert "write_tool" in names
      assert "exec_tool" in names
      assert "search_tool" in names
    end

    test "filters disabled tools" do
      tools = Registry.list_for_llm(agent_mode: :build)
      names = Enum.map(tools, & &1.name)
      refute "disabled_tool" in names
    end

    test "filters by categories" do
      tools = Registry.list_for_llm(categories: [:search])
      names = Enum.map(tools, & &1.name)
      assert "search_tool" in names
      refute "write_tool" in names
      refute "exec_tool" in names
    end

    test "excludes unloaded deferred tools by default" do
      Registry.register_module("deferred_tool", FakeTool, deferred: true)
      tools = Registry.list_for_llm([])
      names = Enum.map(tools, & &1.name)
      refute "deferred_tool" in names
    end

    test "includes deferred tools when include_deferred is true" do
      Registry.register_module("deferred_tool", FakeTool, deferred: true)
      tools = Registry.list_for_llm(include_deferred: true)
      names = Enum.map(tools, & &1.name)
      assert "deferred_tool" in names
    end
  end

  describe "list_by_category/1" do
    setup do
      Registry.register_module("search_tool", SearchTool)
      Registry.register_module("write_tool", WriteTool)

      on_exit(fn ->
        Registry.unregister("search_tool")
        Registry.unregister("write_tool")
      end)

      :ok
    end

    test "returns tools matching the given category" do
      tools = Registry.list_by_category(:search)
      names = Enum.map(tools, & &1.name)
      assert "search_tool" in names
      refute "write_tool" in names
    end
  end

  describe "mark_loaded/1" do
    setup do
      on_exit(fn ->
        Registry.unregister("deferred_tool")
      end)

      :ok
    end

    test "activates a deferred tool" do
      Registry.register_module("deferred_tool", FakeTool, deferred: true)

      # Before mark_loaded, excluded from default list_for_llm/1
      tools_before = Registry.list_for_llm([])
      refute Enum.any?(tools_before, &(&1.name == "deferred_tool"))

      assert :ok = Registry.mark_loaded("deferred_tool")

      # After mark_loaded, included
      tools_after = Registry.list_for_llm([])
      assert Enum.any?(tools_after, &(&1.name == "deferred_tool"))
    end

    test "returns error for non-existent tool" do
      assert {:error, :not_found} = Registry.mark_loaded("nonexistent_xyz")
    end

    test "no-op for non-deferred tool" do
      Registry.register_module("deferred_tool", FakeTool)
      assert :ok = Registry.mark_loaded("deferred_tool")
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
