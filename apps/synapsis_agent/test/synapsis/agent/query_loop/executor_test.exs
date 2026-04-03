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
end
