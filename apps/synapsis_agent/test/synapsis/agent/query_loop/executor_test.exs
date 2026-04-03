defmodule Synapsis.Agent.QueryLoop.ExecutorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop.Executor

  defmodule ReadTool do
    use Synapsis.Tool
    def name, do: "read_tool"
    def description, do: "reads"
    def parameters, do: %{}
    def permission_level, do: :read
    def execute(_input, _ctx), do: {:ok, "read_result"}
  end

  defmodule WriteTool do
    use Synapsis.Tool
    def name, do: "write_tool"
    def description, do: "writes"
    def parameters, do: %{}
    def permission_level, do: :write
    def execute(_input, _ctx), do: {:ok, "write_result"}
  end

  defmodule ErrorTool do
    use Synapsis.Tool
    def name, do: "error_tool"
    def description, do: "errors"
    def parameters, do: %{}
    def permission_level, do: :read
    def execute(_input, _ctx), do: {:error, "something broke"}
  end

  @read_block %{id: "r1", name: "read_tool", input: %{}}
  @write_block %{id: "w1", name: "write_tool", input: %{}}

  describe "partition/2" do
    test "groups consecutive read-only tools into concurrent batch" do
      blocks = [
        %{@read_block | id: "r1"},
        %{@read_block | id: "r2"},
        %{@read_block | id: "r3"}
      ]
      tool_map = %{"read_tool" => ReadTool}

      assert [{:concurrent, ids}] = Executor.partition(blocks, tool_map)
      assert Enum.map(ids, & &1.id) == ["r1", "r2", "r3"]
    end

    test "isolates write tools into serial batches" do
      blocks = [
        %{@write_block | id: "w1"},
        %{@write_block | id: "w2"}
      ]
      tool_map = %{"write_tool" => WriteTool}

      result = Executor.partition(blocks, tool_map)
      assert [{:serial, [%{id: "w1"}]}, {:serial, [%{id: "w2"}]}] = result
    end

    test "handles mixed interleaved sequence" do
      blocks = [
        %{@read_block | id: "r1"},
        %{@read_block | id: "r2"},
        %{@write_block | id: "w1"},
        %{@read_block | id: "r3"},
        %{@write_block | id: "w2"}
      ]
      tool_map = %{"read_tool" => ReadTool, "write_tool" => WriteTool}

      result = Executor.partition(blocks, tool_map)

      assert [
               {:concurrent, [%{id: "r1"}, %{id: "r2"}]},
               {:serial, [%{id: "w1"}]},
               {:concurrent, [%{id: "r3"}]},
               {:serial, [%{id: "w2"}]}
             ] = result
    end

    test "handles single tool call" do
      result = Executor.partition([@read_block], %{"read_tool" => ReadTool})
      assert [{:concurrent, [%{id: "r1"}]}] = result
    end

    test "handles empty list" do
      assert [] = Executor.partition([], %{})
    end

    test "treats unknown tools as serial" do
      blocks = [%{id: "u1", name: "unknown", input: %{}}]
      assert [{:serial, [%{id: "u1"}]}] = Executor.partition(blocks, %{})
    end
  end

  describe "run/3" do
    test "executes concurrent batch in parallel and returns results in order" do
      blocks = [
        %{id: "r1", name: "read_tool", input: %{}},
        %{id: "r2", name: "read_tool", input: %{}}
      ]
      tool_map = %{"read_tool" => ReadTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)

      assert [
               %{tool_use_id: "r1", content: "read_result", is_error: false},
               %{tool_use_id: "r2", content: "read_result", is_error: false}
             ] = results
    end

    test "executes serial batch sequentially" do
      blocks = [
        %{id: "w1", name: "write_tool", input: %{}},
        %{id: "w2", name: "write_tool", input: %{}}
      ]
      tool_map = %{"write_tool" => WriteTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.is_error == false))
    end

    test "formats tool error as is_error result" do
      blocks = [%{id: "e1", name: "error_tool", input: %{}}]
      tool_map = %{"error_tool" => ErrorTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)
      assert [%{tool_use_id: "e1", is_error: true, content: "something broke"}] = results
    end

    test "handles unknown tool with error result" do
      blocks = [%{id: "u1", name: "nonexistent", input: %{}}]
      results = Executor.run(blocks, %{}, %{session_id: "test"})
      assert [%{tool_use_id: "u1", is_error: true}] = results
    end
  end
end
