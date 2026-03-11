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

  # --- Extension tests (T032) ---

  defmodule DisabledExecTool do
    use Synapsis.Tool

    @impl true
    def name, do: "disabled_exec_test"
    @impl true
    def description, do: "Disabled tool"
    @impl true
    def parameters, do: %{}
    @impl true
    def execute(_input, _ctx), do: {:ok, "should not run"}
    @impl true
    def enabled?, do: false
  end

  defmodule TimedTool do
    use Synapsis.Tool

    @impl true
    def name, do: "timed_tool"
    @impl true
    def description, do: "Sleeps configurable ms"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(%{"sleep_ms" => ms}, _ctx) do
      Process.sleep(ms)
      {:ok, "slept #{ms}ms"}
    end

    def execute(_input, _ctx), do: {:ok, "instant"}
  end

  describe "execute/3 enabled check" do
    setup do
      Registry.register_module("disabled_exec_test", DisabledExecTool)
      on_exit(fn -> Registry.unregister("disabled_exec_test") end)
      :ok
    end

    test "returns tool_disabled for disabled tool" do
      assert {:error, :tool_disabled} = Executor.execute("disabled_exec_test", %{}, %{})
    end
  end

  describe "execute/2 map form" do
    test "accepts tool_call map" do
      assert {:ok, "result"} = Executor.execute(%{name: "exec_success", input: %{}}, %{})
    end
  end

  describe "execute_approved/2" do
    test "skips permission check and executes" do
      assert {:ok, "result"} =
               Executor.execute_approved(%{name: "exec_success", input: %{}}, %{})
    end

    test "still checks enabled status" do
      Registry.register_module("disabled_exec_test", DisabledExecTool)
      on_exit(fn -> Registry.unregister("disabled_exec_test") end)

      assert {:error, :tool_disabled} =
               Executor.execute_approved(%{name: "disabled_exec_test", input: %{}}, %{})
    end
  end

  describe "execute_batch/2" do
    setup do
      Registry.register_module("timed_tool", TimedTool, timeout: 5_000)
      on_exit(fn -> Registry.unregister("timed_tool") end)
      :ok
    end

    test "executes multiple calls and returns results in order" do
      calls = [
        %{id: "c1", name: "exec_success", input: %{}},
        %{id: "c2", name: "exec_success", input: %{}},
        %{id: "c3", name: "exec_error", input: %{}}
      ]

      results = Executor.execute_batch(calls, %{})
      assert [{"c1", {:ok, "result"}}, {"c2", {:ok, "result"}}, {"c3", {:error, _}}] = results
    end

    test "runs independent calls in parallel" do
      calls = [
        %{id: "a", name: "timed_tool", input: %{"sleep_ms" => 100}},
        %{id: "b", name: "timed_tool", input: %{"sleep_ms" => 100}}
      ]

      start = System.monotonic_time(:millisecond)
      results = Executor.execute_batch(calls, %{})
      elapsed = System.monotonic_time(:millisecond) - start

      assert length(results) == 2
      # Parallel: should complete in ~100ms, not ~200ms
      assert elapsed < 180
    end

    test "serializes calls targeting the same file path" do
      calls = [
        %{id: "a", name: "timed_tool", input: %{"path" => "/tmp/same.txt", "sleep_ms" => 50}},
        %{id: "b", name: "timed_tool", input: %{"path" => "/tmp/same.txt", "sleep_ms" => 50}}
      ]

      start = System.monotonic_time(:millisecond)
      results = Executor.execute_batch(calls, %{})
      elapsed = System.monotonic_time(:millisecond) - start

      assert length(results) == 2
      # Serialized: should take ~100ms
      assert elapsed >= 90
    end

    test "returns results in original input order" do
      calls = [
        %{id: "first", name: "timed_tool", input: %{"sleep_ms" => 50}},
        %{id: "second", name: "exec_success", input: %{}},
        %{id: "third", name: "exec_success", input: %{}}
      ]

      results = Executor.execute_batch(calls, %{})
      ids = Enum.map(results, fn {id, _} -> id end)
      assert ids == ["first", "second", "third"]
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
