defmodule Synapsis.Agent.QueryLoopForkTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.Context

  setup do
    parent =
      Context.new(
        session_id: "parent_sess",
        system_prompt: "parent prompt",
        tools: [
          %{name: "file_read", description: "read", parameters: %{}, permission_level: :read},
          %{name: "file_write", description: "write", parameters: %{}, permission_level: :write},
          %{name: "bash", description: "exec", parameters: %{}, permission_level: :execute},
          %{name: "grep", description: "search", parameters: %{}, permission_level: :none}
        ],
        model: "claude-sonnet-4-5-20250514",
        provider_config: %{type: "anthropic", api_key: "test"},
        subscriber: self(),
        project_path: "/tmp/test",
        working_dir: "/tmp/test"
      )

    {:ok, parent: parent}
  end

  describe "fork/2" do
    test "creates context with custom system prompt", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "Do this task", subscriber: self())
      assert child.system_prompt == "Do this task"
    end

    test "defaults to read-only tools", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      tool_names = Enum.map(child.tools, & &1.name)
      assert "file_read" in tool_names
      assert "grep" in tool_names
      refute "file_write" in tool_names
      refute "bash" in tool_names
    end

    test "uses explicit tool allowlist", %{parent: parent} do
      child =
        QueryLoop.fork(parent,
          system_prompt: "task",
          subscriber: self(),
          tool_names: ["file_read", "file_write"]
        )

      tool_names = Enum.map(child.tools, & &1.name)
      assert "file_read" in tool_names
      assert "file_write" in tool_names
      refute "bash" in tool_names
      refute "grep" in tool_names
    end

    test "inherits project_path and working_dir", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.project_path == "/tmp/test"
      assert child.working_dir == "/tmp/test"
    end

    test "increments depth", %{parent: parent} do
      assert parent.depth == 0
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.depth == 1

      grandchild = QueryLoop.fork(child, system_prompt: "subtask", subscriber: self())
      assert grandchild.depth == 2
    end

    test "allows model override", %{parent: parent} do
      child =
        QueryLoop.fork(parent,
          system_prompt: "task",
          subscriber: self(),
          model: "claude-haiku-4-5-20251001"
        )

      assert child.model == "claude-haiku-4-5-20251001"
    end

    test "inherits provider_config", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.provider_config == parent.provider_config
    end

    test "gets own abort_ref", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert is_reference(child.abort_ref)
      assert child.abort_ref != parent.abort_ref
    end
  end

  describe "can_fork?/1" do
    test "allows forking at depth 0", %{parent: parent} do
      assert QueryLoop.can_fork?(parent) == true
    end

    test "allows forking at depth 2", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "t", subscriber: self())
      grandchild = QueryLoop.fork(child, system_prompt: "t", subscriber: self())
      assert QueryLoop.can_fork?(grandchild) == true
    end

    test "refuses forking at depth 3", %{parent: parent} do
      c1 = QueryLoop.fork(parent, system_prompt: "t", subscriber: self())
      c2 = QueryLoop.fork(c1, system_prompt: "t", subscriber: self())
      c3 = QueryLoop.fork(c2, system_prompt: "t", subscriber: self())
      assert QueryLoop.can_fork?(c3) == false
    end
  end
end
