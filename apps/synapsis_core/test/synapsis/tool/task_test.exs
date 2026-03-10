defmodule Synapsis.Tool.TaskTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Task

  describe "tool metadata" do
    test "has correct name" do
      assert Task.name() == "task"
    end

    test "has a description string" do
      assert is_binary(Task.description())
      assert String.length(Task.description()) > 0
    end

    test "has valid parameters schema" do
      params = Task.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "prompt" in params["required"]
    end

    test "permission_level is :none" do
      assert Task.permission_level() == :none
    end

    test "category is :orchestration" do
      assert Task.category() == :orchestration
    end
  end

  describe "execute/2 — foreground mode" do
    test "returns result with task id" do
      input = %{"prompt" => "Analyze the codebase", "mode" => "foreground"}
      context = %{session_id: "test-session-123"}

      assert {:ok, result} = Task.execute(input, context)
      assert result =~ "Sub-agent task"
      assert result =~ "completed for:"
      assert result =~ "Analyze the codebase"
    end

    test "defaults to foreground mode when mode not specified" do
      input = %{"prompt" => "Do something"}
      context = %{session_id: "test-session-123"}

      assert {:ok, result} = Task.execute(input, context)
      assert result =~ "completed for:"
    end
  end

  describe "execute/2 — background mode" do
    test "returns task_id and running status" do
      input = %{"prompt" => "Long running task", "mode" => "background"}
      context = %{session_id: "test-session-123"}

      assert {:ok, json} = Task.execute(input, context)
      decoded = Jason.decode!(json)
      assert is_binary(decoded["task_id"])
      assert decoded["status"] == "running"
      assert decoded["prompt"] =~ "Long running task"
    end
  end

  describe "execute/2 — error cases" do
    test "returns error without session_id" do
      input = %{"prompt" => "Do something"}
      context = %{}

      assert {:error, "No session context available for sub-agent"} =
               Task.execute(input, context)
    end

    test "returns error for invalid mode" do
      input = %{"prompt" => "Do something", "mode" => "invalid"}
      context = %{session_id: "test-session-123"}

      assert {:error, msg} = Task.execute(input, context)
      assert msg =~ "Invalid mode"
    end
  end
end
