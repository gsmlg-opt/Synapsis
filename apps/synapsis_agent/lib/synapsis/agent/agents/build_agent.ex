defmodule Synapsis.Agent.Agents.BuildAgent do
  @moduledoc "Ephemeral Build Agent — executes a single task in a git worktree."
  use GenServer, restart: :temporary

  defstruct [
    :session_id,
    :repo_id,
    :worktree_id,
    :worktree_path,
    :task,
    :parent_agent_id,
    :status
  ]

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    state = %__MODULE__{
      session_id: config.session_id,
      repo_id: config.repo_id,
      worktree_id: config.worktree_id,
      worktree_path: config.worktree_path,
      task: config.task,
      parent_agent_id: config.parent_agent_id,
      status: :initializing
    }

    {:ok, state}
  end
end
