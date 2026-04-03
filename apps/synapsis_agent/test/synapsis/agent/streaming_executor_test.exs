defmodule Synapsis.Agent.StreamingExecutorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.StreamingExecutor

  defmodule FastReadTool do
    use Synapsis.Tool
    def name, do: "fast_read"
    def description, do: "fast read"
    def parameters, do: %{}
    def permission_level, do: :read

    def execute(_input, _ctx) do
      Process.sleep(10)
      {:ok, "fast_read_result"}
    end
  end

  defmodule SlowWriteTool do
    use Synapsis.Tool
    def name, do: "slow_write"
    def description, do: "slow write"
    def parameters, do: %{}
    def permission_level, do: :write

    def execute(_input, _ctx) do
      Process.sleep(50)
      {:ok, "slow_write_result"}
    end
  end

  @tool_map %{"fast_read" => FastReadTool, "slow_write" => SlowWriteTool}
  @ctx %{session_id: "test"}

  describe "new/2" do
    test "creates empty executor" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      assert exec.tools == []
      assert exec.next_order == 0
    end
  end

  describe "add_tool/2" do
    test "starts concurrent-safe tool immediately" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})

      assert length(exec.tools) == 1
      assert hd(exec.tools).status == :executing
    end

    test "queues serial tool when concurrent tools are running" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "w1", name: "slow_write", input: %{}})

      write_tool = Enum.find(exec.tools, &(&1.id == "w1"))
      assert write_tool.status == :queued
    end

    test "handles unknown tool" do
      exec = StreamingExecutor.new(%{}, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "u1", name: "unknown", input: %{}})
      # Unknown tools are serial (not concurrent-safe) but should still be queued/started
      assert length(exec.tools) == 1
    end
  end

  describe "get_completed_results/1" do
    test "returns completed tool results" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})

      # Wait for tool to complete
      Process.sleep(30)

      {results, _exec} = StreamingExecutor.get_completed_results(exec)
      assert length(results) == 1
      assert hd(results).tool_use_id == "r1"
      assert hd(results).content == "fast_read_result"
    end

    test "returns empty when nothing completed yet" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      {results, _exec} = StreamingExecutor.get_completed_results(exec)
      assert results == []
    end
  end

  describe "get_remaining_results/1" do
    test "waits for all in-flight tools and returns in order" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "r2", name: "fast_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)
      assert length(results) == 2
      assert Enum.map(results, & &1.tool_use_id) == ["r1", "r2"]
      assert Enum.all?(results, &(&1.content == "fast_read_result"))
    end

    test "returns results in submission order not completion order" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "w1", name: "slow_write", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)
      # Even though fast_read finishes first, results are in submission order
      assert Enum.map(results, & &1.tool_use_id) == ["w1", "r1"]
    end

    test "handles mix of already-completed and in-flight" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      Process.sleep(30)
      exec = StreamingExecutor.add_tool(exec, %{id: "r2", name: "fast_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)
      assert length(results) == 2
    end
  end
end
