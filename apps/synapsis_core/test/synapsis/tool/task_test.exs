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

    test "is enabled" do
      assert Task.enabled?() == true
    end
  end

  describe "execute/2 — error cases" do
    test "returns error without session_id" do
      input = %{"prompt" => "Do something"}
      context = %{}

      assert {:error, "No session context available for sub-agent"} =
               Task.execute(input, context)
    end

    test "returns error without project_id" do
      input = %{"prompt" => "Do something"}
      context = %{session_id: "test-session-123"}

      assert {:error, "No project context available for sub-agent"} =
               Task.execute(input, context)
    end

    test "returns error for invalid mode" do
      input = %{"prompt" => "Do something", "mode" => "invalid"}
      context = %{session_id: "test-session-123", project_id: "test-project-456"}

      assert {:error, msg} = Task.execute(input, context)
      assert msg =~ "Invalid mode"
    end
  end
end
