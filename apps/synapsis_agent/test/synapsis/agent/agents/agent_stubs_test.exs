defmodule Synapsis.Agent.Agents.AgentStubsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Agents.AssistantAgent
  alias Synapsis.Agent.Agents.BuildAgent

  describe "AssistantAgent" do
    setup do
      # Start a fresh AssistantAgent for each test, using a unique name to avoid conflicts
      name = :"assistant_agent_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(AssistantAgent, [], name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid, name: name}
    end

    test "starts with :global context mode", %{pid: pid} do
      mode = GenServer.call(pid, :current_mode)
      assert mode == :global
    end

    test "switch_project changes context mode", %{pid: pid} do
      project_id = Ecto.UUID.generate()
      assert :ok = GenServer.call(pid, {:switch_project, project_id})
      mode = GenServer.call(pid, :current_mode)
      assert mode == {:project, project_id}
    end

    test "switch_project sets the project_id", %{pid: pid} do
      project_id = Ecto.UUID.generate()
      GenServer.call(pid, {:switch_project, project_id})
      # Verify state by switching to another project
      project_id2 = Ecto.UUID.generate()
      GenServer.call(pid, {:switch_project, project_id2})
      mode = GenServer.call(pid, :current_mode)
      assert mode == {:project, project_id2}
    end

    test "handles :notification info message without crashing", %{pid: pid} do
      send(pid, {:notification, %{event: "test"}})
      # Give it a moment to process
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  describe "BuildAgent" do
    test "starts with config and stores state correctly" do
      config = %{
        session_id: Ecto.UUID.generate(),
        repo_id: Ecto.UUID.generate(),
        worktree_id: Ecto.UUID.generate(),
        worktree_path: "/tmp/test-worktree",
        task: "implement feature X",
        parent_agent_id: Ecto.UUID.generate()
      }

      {:ok, pid} = BuildAgent.start_link(config)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)

      assert state.session_id == config.session_id
      assert state.repo_id == config.repo_id
      assert state.worktree_id == config.worktree_id
      assert state.worktree_path == config.worktree_path
      assert state.task == config.task
      assert state.parent_agent_id == config.parent_agent_id
      assert state.status == :initializing
    end

    test "starts successfully with minimal config" do
      config = %{
        session_id: Ecto.UUID.generate(),
        repo_id: Ecto.UUID.generate(),
        worktree_id: Ecto.UUID.generate(),
        worktree_path: "/tmp/test",
        task: "do something",
        parent_agent_id: nil
      }

      assert {:ok, pid} = BuildAgent.start_link(config)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert Process.alive?(pid)
    end
  end
end
