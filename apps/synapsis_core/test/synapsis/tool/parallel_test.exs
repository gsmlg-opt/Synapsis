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
      results = Executor.execute_batch(calls, %{})
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

      results = Executor.execute_batch(calls, %{})
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
          Executor.execute_batch(calls, %{})
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

      results = Executor.execute_batch(calls, %{})

      result_map = Map.new(results)
      assert {:ok, "done"} = result_map["ok_1"]
      assert {:ok, "done"} = result_map["ok_2"]
      assert {:ok, "done"} = result_map["ok_3"]
      assert {:error, "intentional failure"} = result_map["fail_1"]
      assert {:error, "intentional failure"} = result_map["fail_2"]
    end
  end

  describe "timeout and retry handling" do
    test "retries retry-safe module tools after timeout" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Registry.register_module("parallel_test_flaky_timeout", FlakyTimeoutTool, timeout: 20)

      on_exit(fn ->
        Registry.unregister("parallel_test_flaky_timeout")
      end)

      assert {:ok, "retried"} =
               Executor.execute_approved(
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
               Executor.execute_approved(
                 "parallel_test_never_reply",
                 %{},
                 %{tool_max_retries: 1, tool_retry_backoff_ms: 0}
               )

      assert Agent.get(counter, & &1) == 2
    end
  end
end
