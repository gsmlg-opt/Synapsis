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
end
