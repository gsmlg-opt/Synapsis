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

  defmodule HangingReadTool do
    use Synapsis.Tool
    def name, do: "hanging_read"
    def description, do: "never returns"
    def parameters, do: %{}
    def permission_level, do: :read
    def execute(_input, _ctx), do: Process.sleep(:infinity)
  end

  defmodule BlockingReadTool do
    use Synapsis.Tool
    def name, do: "blocking_read"
    def description, do: "controlled read"
    def parameters, do: %{}
    def permission_level, do: :read

    def execute(input, ctx) do
      label = input["label"]
      send(ctx.owner, {:streaming_tool_started, label, self()})

      receive do
        {:release_streaming_tool, ^label} -> {:ok, label}
      end
    end
  end

  defmodule BlockingWriteTool do
    use Synapsis.Tool
    def name, do: "blocking_write"
    def description, do: "controlled write"
    def parameters, do: %{}
    def permission_level, do: :write

    def execute(input, ctx) do
      label = input["label"]
      send(ctx.owner, {:streaming_tool_started, label, self()})

      receive do
        {:release_streaming_tool, ^label} -> {:ok, label}
      end
    end
  end

  @tool_map %{
    "fast_read" => FastReadTool,
    "slow_write" => SlowWriteTool,
    "hanging_read" => HangingReadTool,
    "blocking_read" => BlockingReadTool,
    "blocking_write" => BlockingWriteTool
  }

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

    test "treats process registrations without a permission as serial" do
      tool_map = %{
        "first" => {:process, self(), []},
        "second" => {:process, self(), []}
      }

      exec = StreamingExecutor.new(tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "p1", name: "first", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "p2", name: "second", input: %{}})

      assert Enum.find(exec.tools, &(&1.id == "p1")).status == :executing
      assert Enum.find(exec.tools, &(&1.id == "p2")).status == :queued

      Enum.each(exec.tools, fn tool ->
        if is_pid(tool.task_pid), do: Process.exit(tool.task_pid, :kill)
      end)
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

    test "starts queued writes one at a time after earlier reads complete" do
      ctx = Map.put(@ctx, :owner, self())

      exec =
        @tool_map
        |> StreamingExecutor.new(ctx)
        |> StreamingExecutor.add_tool(%{
          id: "r1",
          name: "blocking_read",
          input: %{"label" => "read"}
        })
        |> StreamingExecutor.add_tool(%{
          id: "w1",
          name: "blocking_write",
          input: %{"label" => "write-one"}
        })
        |> StreamingExecutor.add_tool(%{
          id: "w2",
          name: "blocking_write",
          input: %{"label" => "write-two"}
        })

      assert_receive {:streaming_tool_started, "read", read_pid}
      send(read_pid, {:release_streaming_tool, "read"})
      Process.sleep(10)

      {read_results, exec} = StreamingExecutor.get_completed_results(exec)
      assert Enum.map(read_results, & &1.tool_use_id) == ["r1"]
      assert_receive {:streaming_tool_started, "write-one", write_one_pid}
      refute_receive {:streaming_tool_started, "write-two", _pid}, 100

      send(write_one_pid, {:release_streaming_tool, "write-one"})
      Process.sleep(10)
      {write_one_results, exec} = StreamingExecutor.get_completed_results(exec)
      assert Enum.map(write_one_results, & &1.tool_use_id) == ["w1"]
      assert_receive {:streaming_tool_started, "write-two", write_two_pid}
      send(write_two_pid, {:release_streaming_tool, "write-two"})

      {write_two_results, _exec} = StreamingExecutor.get_remaining_results(exec)
      assert Enum.map(write_two_results, & &1.tool_use_id) == ["w2"]
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

    test "times out in-flight tools and returns the result id" do
      ctx = Map.merge(@ctx, %{tool_timeout_ms: 20, tool_max_retries: 0})

      exec =
        @tool_map
        |> StreamingExecutor.new(ctx)
        |> StreamingExecutor.add_tool(%{id: "r_timeout", name: "hanging_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)

      assert [
               %{
                 tool_use_id: "r_timeout",
                 content: "Tool execution timed out",
                 is_error: true
               }
             ] = results
    end

    test "drains queued writes serially" do
      owner = self()

      task =
        Task.async(fn ->
          exec =
            @tool_map
            |> StreamingExecutor.new(Map.put(@ctx, :owner, owner))
            |> StreamingExecutor.add_tool(%{
              id: "r1",
              name: "blocking_read",
              input: %{"label" => "drain-read"}
            })
            |> StreamingExecutor.add_tool(%{
              id: "w1",
              name: "blocking_write",
              input: %{"label" => "drain-write-one"}
            })
            |> StreamingExecutor.add_tool(%{
              id: "w2",
              name: "blocking_write",
              input: %{"label" => "drain-write-two"}
            })

          StreamingExecutor.get_remaining_results(exec)
        end)

      assert_receive {:streaming_tool_started, "drain-read", read_pid}
      send(read_pid, {:release_streaming_tool, "drain-read"})
      assert_receive {:streaming_tool_started, "drain-write-one", write_one_pid}
      refute_receive {:streaming_tool_started, "drain-write-two", _pid}, 100

      send(write_one_pid, {:release_streaming_tool, "drain-write-one"})
      assert_receive {:streaming_tool_started, "drain-write-two", write_two_pid}
      send(write_two_pid, {:release_streaming_tool, "drain-write-two"})

      assert {results, _exec} = Task.await(task, 2_000)
      assert Enum.map(results, & &1.tool_use_id) == ["r1", "w1", "w2"]
    end
  end
end
