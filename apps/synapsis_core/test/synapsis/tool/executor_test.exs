defmodule Synapsis.Tool.ExecutorTest do
  use ExUnit.Case

  alias Synapsis.Tool.{Executor, Registry}

  defmodule SuccessTool do
    def description, do: "succeeds"
    def parameters, do: %{}
    def execute(_input, _ctx), do: {:ok, "result"}
  end

  defmodule ErrorTool do
    def description, do: "errors"
    def parameters, do: %{}
    def execute(_input, _ctx), do: {:error, "something broke"}
  end

  defmodule SlowTool do
    def description, do: "slow"
    def parameters, do: %{}
    def execute(_input, _ctx), do: Process.sleep(:infinity)
  end

  defmodule CrashTool do
    def description, do: "crashes"
    def parameters, do: %{}
    def execute(_input, _ctx), do: raise("boom")
  end

  defmodule SideEffectTool do
    def description, do: "side effects"
    def parameters, do: %{}
    def execute(_input, _ctx), do: {:ok, "done"}
    def side_effects, do: [:file_changed, :project_modified]
  end

  setup do
    on_exit(fn ->
      Registry.unregister("exec_success")
      Registry.unregister("exec_error")
      Registry.unregister("exec_slow")
      Registry.unregister("exec_crash")
      Registry.unregister("exec_side_effect")
      Registry.unregister("exec_process")
    end)

    Registry.register_module("exec_success", SuccessTool)
    Registry.register_module("exec_error", ErrorTool)
    Registry.register_module("exec_slow", SlowTool, timeout: 100)
    Registry.register_module("exec_crash", CrashTool)
    Registry.register_module("exec_side_effect", SideEffectTool)
    :ok
  end

  describe "execute/3 with module tools" do
    test "returns ok for successful tool" do
      assert {:ok, "result"} = Executor.execute("exec_success", %{}, %{})
    end

    test "returns error for failing tool" do
      assert {:error, "something broke"} = Executor.execute("exec_error", %{}, %{})
    end

    test "returns timeout error for slow tool" do
      assert {:error, :timeout} = Executor.execute("exec_slow", %{}, %{})
    end

    test "returns error for crashing tool" do
      result = Executor.execute("exec_crash", %{}, %{})
      assert {:error, {:exit, _}} = result
    end

    test "returns error for unknown tool" do
      assert {:error, "Unknown tool: nonexistent"} = Executor.execute("nonexistent", %{}, %{})
    end
  end

  describe "execute/3 broadcasts side effects" do
    test "broadcasts side effects for tools that define them" do
      session_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_effects:#{session_id}")

      assert {:ok, "done"} = Executor.execute("exec_side_effect", %{}, %{session_id: session_id})

      assert_receive {:tool_effect, :file_changed, %{session_id: ^session_id}}
      assert_receive {:tool_effect, :project_modified, %{session_id: ^session_id}}
    end

    test "does not broadcast when no session_id" do
      # Should not crash when no session_id in context
      assert {:ok, "done"} = Executor.execute("exec_side_effect", %{}, %{})
    end
  end

  describe "execute/3 with process tools" do
    test "calls GenServer for process-based tool" do
      {:ok, server} =
        GenServer.start_link(
          Synapsis.Tool.ExecutorTest.FakeToolServer,
          :ok
        )

      Registry.register_process("exec_process", server, timeout: 5_000)

      assert {:ok, "process result"} =
               Executor.execute("exec_process", %{"key" => "val"}, %{})

      GenServer.stop(server)
    end

    test "process tool timeout returns {:error, :timeout}" do
      {:ok, server} =
        GenServer.start_link(Synapsis.Tool.ExecutorTest.SlowProcessServer, :ok)

      Registry.register_process("exec_proc_slow", server, timeout: 100)
      on_exit(fn -> Registry.unregister("exec_proc_slow") end)

      assert {:error, :timeout} = Executor.execute("exec_proc_slow", %{}, %{})
    end

    test "process tool crash returns {:error, {:exit, reason}}" do
      # Use start (not start_link) so test process isn't linked and doesn't crash
      {:ok, server} =
        GenServer.start(Synapsis.Tool.ExecutorTest.CrashProcessServer, :ok)

      Registry.register_process("exec_proc_crash", server)
      on_exit(fn -> Registry.unregister("exec_proc_crash") end)

      assert {:error, {:exit, _reason}} = Executor.execute("exec_proc_crash", %{}, %{})
    end
  end

  defmodule FakeToolServer do
    use GenServer

    def init(:ok), do: {:ok, :ok}

    def handle_call({:execute, _name, _input, _ctx}, _from, state) do
      {:reply, {:ok, "process result"}, state}
    end
  end

  defmodule SlowProcessServer do
    use GenServer

    def init(:ok), do: {:ok, :ok}

    def handle_call({:execute, _, _, _}, _from, state) do
      Process.sleep(:infinity)
      {:reply, {:ok, "never"}, state}
    end
  end

  defmodule CrashProcessServer do
    use GenServer

    def init(:ok), do: {:ok, :ok}

    def handle_call({:execute, _, _, _}, _from, _state) do
      exit(:boom)
    end
  end
end
