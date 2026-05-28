defmodule Synapsis.Agent.ToolDispatcherTest.UnexpectedReturnTool do
  @moduledoc false
  def execute(_input, _context), do: :unexpected_return
  def description, do: "Test tool returning unexpected value"
  def parameters, do: %{"type" => "object", "properties" => %{}}
  def permission_level, do: :write
end

defmodule Synapsis.Agent.ToolDispatcherTest.CrashingTool do
  @moduledoc false
  def execute(_input, _context), do: raise("deliberate test crash")
  def description, do: "Test tool that crashes"
  def parameters, do: %{"type" => "object", "properties" => %{}}
  def permission_level, do: :write
end

defmodule Synapsis.Agent.ToolDispatcherTest.SuccessTool do
  @moduledoc false
  def execute(_input, _context), do: {:ok, "success output"}
  def description, do: "Test tool that succeeds"
  def parameters, do: %{"type" => "object", "properties" => %{}}
  def permission_level, do: :write
end

defmodule Synapsis.Agent.ToolDispatcherTest.ErrorTool do
  @moduledoc false
  def execute(_input, _context), do: {:error, "something went wrong"}
  def description, do: "Test tool that errors"
  def parameters, do: %{"type" => "object", "properties" => %{}}
  def permission_level, do: :write
end

defmodule Synapsis.Agent.ToolDispatcherTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.ToolDispatcher

  @unexpected_tool __MODULE__.UnexpectedReturnTool
  @crashing_tool __MODULE__.CrashingTool
  @success_tool __MODULE__.SuccessTool
  @error_tool __MODULE__.ErrorTool

  # A mock tool_use struct
  defp make_tool_use(name, input \\ %{}) do
    %{
      tool: name,
      tool_use_id: "tu_#{System.unique_integer([:positive])}",
      input: input
    }
  end

  defp unique_tool_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  @test_session_id "00000000-0000-0000-0000-000000000000"

  describe "execute_async/3 error handling" do
    test "sends error tool_result when executor returns unexpected value" do
      tool_name = unique_tool_name("test_unexpected")
      Synapsis.Tool.Registry.register_module(tool_name, @unexpected_tool)

      tool_use = make_tool_use(tool_name)
      caller = self()

      _task =
        ToolDispatcher.execute_async(tool_use, caller, %{
          project_path: "/tmp",
          session_id: @test_session_id
        })

      # The unexpected return (:unexpected_return atom) gets wrapped as {:ok, :unexpected_return}
      # by the executor, then our case matches {:ok, output} but string operations on the
      # atom crash — the try/rescue catches this and sends an error result
      assert_receive {:tool_result, id, content, true}, 5_000
      assert id == tool_use.tool_use_id
      assert is_binary(content)
    end

    test "sends error tool_result when executor crashes with exception" do
      tool_name = unique_tool_name("test_crash")
      Synapsis.Tool.Registry.register_module(tool_name, @crashing_tool)

      tool_use = make_tool_use(tool_name)
      caller = self()

      _task =
        ToolDispatcher.execute_async(tool_use, caller, %{
          project_path: "/tmp",
          session_id: @test_session_id
        })

      # Should still receive a tool_result with is_error=true
      assert_receive {:tool_result, id, content, true}, 5_000
      assert id == tool_use.tool_use_id
      assert is_binary(content)
      assert content =~ "crash" or content =~ "error" or content =~ "failed"
    end

    test "sends success tool_result on normal execution" do
      tool_name = unique_tool_name("test_success")
      Synapsis.Tool.Registry.register_module(tool_name, @success_tool)

      tool_use = make_tool_use(tool_name)
      caller = self()

      _task =
        ToolDispatcher.execute_async(tool_use, caller, %{
          project_path: "/tmp",
          session_id: @test_session_id
        })

      assert_receive {:tool_result, id, content, false}, 5_000
      assert id == tool_use.tool_use_id
      assert content == "success output"
    end

    test "sends error tool_result on normal error return" do
      tool_name = unique_tool_name("test_error_return")
      Synapsis.Tool.Registry.register_module(tool_name, @error_tool)

      tool_use = make_tool_use(tool_name)
      caller = self()

      _task =
        ToolDispatcher.execute_async(tool_use, caller, %{
          project_path: "/tmp",
          session_id: @test_session_id
        })

      assert_receive {:tool_result, id, content, true}, 5_000
      assert id == tool_use.tool_use_id
      assert content =~ "something went wrong"
    end

    test "sends error tool_result for unknown tool" do
      tool_use = make_tool_use("nonexistent_tool_#{System.unique_integer([:positive])}")
      caller = self()

      _task =
        ToolDispatcher.execute_async(tool_use, caller, %{
          project_path: "/tmp",
          session_id: @test_session_id
        })

      assert_receive {:tool_result, id, content, true}, 5_000
      assert id == tool_use.tool_use_id
      assert content =~ "Unknown tool"
    end
  end

  describe "dispatch_all/4 return value" do
    test "returns {hashes, task_refs} tuple" do
      tool_use = make_tool_use("file_read", %{"path" => "test.txt"})

      result =
        ToolDispatcher.dispatch_all(
          [{:denied, tool_use}],
          self(),
          "test_session",
          %{}
        )

      assert {%MapSet{}, %MapSet{}} = result
    end

    test "denied tools produce empty task_refs" do
      tool_use = make_tool_use("file_read")

      {_hashes, task_refs} =
        ToolDispatcher.dispatch_all(
          [{:denied, tool_use}],
          self(),
          "test_session",
          %{}
        )

      assert MapSet.size(task_refs) == 0

      # Should still receive the denied result
      assert_receive {:tool_result, _, "Tool denied by permission policy.", true}
    end

    test "approved tools produce task_refs" do
      tool_name = unique_tool_name("test_dispatch_approved")
      Synapsis.Tool.Registry.register_module(tool_name, @success_tool)

      tool_use = make_tool_use(tool_name)

      {_hashes, task_refs} =
        ToolDispatcher.dispatch_all(
          [{:approved, tool_use}],
          self(),
          "test_session",
          %{project_path: "/tmp"}
        )

      assert MapSet.size(task_refs) == 1

      # Should receive the success result
      assert_receive {:tool_result, _, "success output", false}, 5_000
    end
  end
end
