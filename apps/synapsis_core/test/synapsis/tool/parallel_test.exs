defmodule Synapsis.Tool.ParallelTest do
  use ExUnit.Case

  alias Synapsis.Tool.{Executor, Registry}

  defmodule SlowMockTool do
    use Synapsis.Tool

    @impl true
    def name, do: "parallel_test_slow"
    @impl true
    def description, do: "Sleeps 50ms for parallel testing"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_input, _ctx) do
      Process.sleep(50)
      {:ok, "done"}
    end
  end

  defmodule FlakyTimeoutTool do
    use Synapsis.Tool

    @impl true
    def name, do: "parallel_test_flaky_timeout"
    @impl true
    def description, do: "Times out once, then succeeds"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def permission_level, do: :read

    @impl true
    def execute(%{counter: counter}, _ctx) do
      attempt = Agent.get_and_update(counter, &{&1, &1 + 1})

      if attempt == 0 do
        Process.sleep(:infinity)
      else
        {:ok, "retried"}
      end
    end
  end

  defmodule NeverReplyProcessTool do
    use GenServer

    def start_link(counter), do: GenServer.start_link(__MODULE__, counter)
    def init(counter), do: {:ok, counter}

    def handle_call({:execute, _tool_name, _input, _context}, _from, counter) do
      Agent.update(counter, &(&1 + 1))
      {:noreply, counter}
    end
  end

  defmodule ReplyProcessTool do
    use GenServer

    def start_link({owner, result}), do: GenServer.start_link(__MODULE__, {owner, result})
    def init(state), do: {:ok, state}

    def handle_call({:execute, tool_name, _input, _context}, _from, {owner, result} = state) do
      send(owner, {:process_tool_executed, tool_name})
      {:reply, result, state}
    end
  end

  setup do
    Registry.register_module("parallel_test_slow", SlowMockTool, timeout: 5_000)

    on_exit(fn ->
      Registry.unregister("parallel_test_slow")
    end)

    :ok
  end

  describe "execute_batch/2 parallel execution" do
    test "5 independent calls complete faster than sequential" do
      calls =
        for i <- 1..5 do
          %{id: "call_#{i}", name: "parallel_test_slow", input: %{}}
        end

      start = System.monotonic_time(:millisecond)
      results = Executor.execute_batch(calls, %{
            session_id: "parallel-batch-session",
            permission_mode: "yolo",
            attended?: true
          })
      elapsed = System.monotonic_time(:millisecond) - start

      # All 5 should succeed
      assert length(results) == 5

      for {_id, result} <- results do
        assert {:ok, "done"} = result
      end

      # Sequential would take ~250ms; parallel should be < 150ms
      assert elapsed < 150,
             "Expected parallel execution in < 150ms, took #{elapsed}ms (sequential would be ~250ms)"
    end

    test "results are returned in original input order" do
      calls =
        for i <- 1..5 do
          %{id: "ord_#{i}", name: "parallel_test_slow", input: %{}}
        end

      results = Executor.execute_batch(calls, %{
            session_id: "parallel-batch-session",
            permission_mode: "yolo",
            attended?: true
          })
      ids = Enum.map(results, fn {id, _} -> id end)

      assert ids == ["ord_1", "ord_2", "ord_3", "ord_4", "ord_5"]
    end

    test "10 concurrent calls complete without deadlock" do
      calls =
        for i <- 1..10 do
          %{id: "conc_#{i}", name: "parallel_test_slow", input: %{}}
        end

      # Should complete within a reasonable time (no deadlock)
      # 10 calls * 50ms each, even with limited parallelism, should be well under 2s
      task =
        Task.async(fn ->
          Executor.execute_batch(calls, %{
            session_id: "parallel-batch-session",
            permission_mode: "yolo",
            attended?: true
          })
        end)

      results = Task.await(task, 2_000)

      assert length(results) == 10

      for {_id, result} <- results do
        assert {:ok, "done"} = result
      end
    end

    test "mixed success and failure calls in parallel" do
      # Register a failing tool
      defmodule FailMockTool do
        def description, do: "Always fails"
        def parameters, do: %{}
        def execute(_input, _ctx), do: {:error, "intentional failure"}
      end

      Registry.register_module("parallel_test_fail", FailMockTool)
      on_exit(fn -> Registry.unregister("parallel_test_fail") end)

      calls = [
        %{id: "ok_1", name: "parallel_test_slow", input: %{}},
        %{id: "fail_1", name: "parallel_test_fail", input: %{}},
        %{id: "ok_2", name: "parallel_test_slow", input: %{}},
        %{id: "fail_2", name: "parallel_test_fail", input: %{}},
        %{id: "ok_3", name: "parallel_test_slow", input: %{}}
      ]

      results = Executor.execute_batch(calls, %{
            session_id: "parallel-batch-session",
            permission_mode: "yolo",
            attended?: true
          })

      result_map = Map.new(results)
      assert {:ok, "done"} = result_map["ok_1"]
      assert {:ok, "done"} = result_map["ok_2"]
      assert {:ok, "done"} = result_map["ok_3"]
      assert {:error, "intentional failure"} = result_map["fail_1"]
      assert {:error, "intentional failure"} = result_map["fail_2"]
    end
  end

  describe "timeout and retry handling" do
    test "rejects a disabled process tool at dispatch" do
      name = "parallel_test_disabled_process_#{System.unique_integer([:positive])}"
      pid = start_supervised!({ReplyProcessTool, {self(), {:ok, "ran"}}})

      Registry.register_process(name, pid, enabled: false, permission_level: :read)
      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :tool_disabled} = Executor.execute_approved(name, %{}, %{})
      refute_receive {:process_tool_executed, ^name}
    end

    test "fails closed when a process runtime availability check changes" do
      name = "parallel_test_unavailable_process_#{System.unique_integer([:positive])}"
      pid = start_supervised!({ReplyProcessTool, {self(), {:ok, "ran"}}})
      {:ok, available} = Agent.start_link(fn -> true end)

      Registry.register_process(name, pid,
        permission_level: :read,
        availability_check: fn -> Agent.get(available, & &1) end
      )

      on_exit(fn -> Registry.unregister(name) end)
      Agent.update(available, fn _ -> false end)

      assert {:error, :tool_disabled} = Executor.execute_approved(name, %{}, %{})
      refute_receive {:process_tool_executed, ^name}
    end

    test "rejects a disabled module tool at dispatch" do
      name = "parallel_test_disabled_module_#{System.unique_integer([:positive])}"
      Registry.register_module(name, SlowMockTool, enabled: false)
      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :tool_disabled} = Executor.execute_approved(name, %{}, %{})
    end

    test "rejects an unloaded deferred module tool at dispatch" do
      name = "parallel_test_deferred_module_#{System.unique_integer([:positive])}"
      Registry.register_module(name, SlowMockTool, deferred: true)
      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :tool_deferred} = Executor.execute_approved(name, %{}, %{})
    end

    test "rejects an unloaded deferred process tool at dispatch" do
      name = "parallel_test_deferred_process_#{System.unique_integer([:positive])}"
      pid = start_supervised!({ReplyProcessTool, {self(), {:ok, "ran"}}})

      Registry.register_process(name, pid, deferred: true, permission_level: :read)
      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :tool_deferred} = Executor.execute_approved(name, %{}, %{})
      refute_receive {:process_tool_executed, ^name}
    end

    test "rejects a same-name process replacement after admission" do
      name = "parallel_test_replaced_process_#{System.unique_integer([:positive])}"

      admitted =
        start_supervised!({ReplyProcessTool, {self(), {:ok, "old"}}}, id: {:admitted, name})

      replacement =
        start_supervised!({ReplyProcessTool, {self(), {:ok, "new"}}}, id: {:replacement, name})

      Registry.register_process(name, admitted, permission_level: :read)
      assert {:ok, expected_entry} = Registry.lookup(name)
      Registry.register_process(name, replacement, permission_level: :write)
      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :tool_registration_changed} =
               Executor.dispatch_granted(name, %{}, %{}, expected_entry)

      refute_receive {:process_tool_executed, ^name}
    end

    test "does not retry MCP process tools by default" do
      name = "parallel_test_mcp_no_retry_#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, pid} = NeverReplyProcessTool.start_link(counter)

      Registry.register_process(name, pid,
        timeout: 20,
        permission_level: :read,
        category: :mcp
      )

      on_exit(fn -> Registry.unregister(name) end)

      assert {:error, :timeout} = Executor.execute_approved(name, %{}, %{})
      assert Agent.get(counter, & &1) == 1
    end

    test "retries retry-safe module tools after timeout" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Registry.register_module("parallel_test_flaky_timeout", FlakyTimeoutTool, timeout: 20)

      on_exit(fn ->
        Registry.unregister("parallel_test_flaky_timeout")
      end)

      assert {:ok, "retried"} =
               Synapsis.Tool.Executor.dispatch_granted(
                 "parallel_test_flaky_timeout",
                 %{counter: counter},
                 %{tool_max_retries: 1, tool_retry_backoff_ms: 0}
               )

      assert Agent.get(counter, & &1) == 2
    end

    test "times out and retries process tools without blocking forever" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, pid} = NeverReplyProcessTool.start_link(counter)

      Registry.register_process("parallel_test_never_reply", pid,
        timeout: 20,
        permission_level: :read
      )

      on_exit(fn ->
        Registry.unregister("parallel_test_never_reply")
      end)

      assert {:error, :timeout} =
               Synapsis.Tool.Executor.dispatch_granted(
                 "parallel_test_never_reply",
                 %{},
                 %{tool_max_retries: 1, tool_retry_backoff_ms: 0}
               )

      assert Agent.get(counter, & &1) == 2
    end
  end
end
