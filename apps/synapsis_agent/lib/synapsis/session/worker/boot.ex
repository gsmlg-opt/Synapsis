defmodule Synapsis.Session.Worker.Boot do
  @moduledoc "Handles Worker initialization: session loading, graph creation, Runner start."

  alias Synapsis.{Repo, Session}
  alias Synapsis.Session.WorkspaceManager
  alias Synapsis.Session.Worker.Config
  alias Synapsis.Agent.Runtime.Runner
  alias Synapsis.Agent.Graphs.CodingLoop

  def load_and_boot(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:stop, {:error, :session_not_found}}
      session -> boot(Repo.preload(session, :project), session_id)
    end
  end

  defp boot(session, session_id) do
    Process.flag(:trap_exit, true)

    agent = Config.resolve_agent(session)
    provider = agent[:provider] || session.provider
    provider_config = Config.resolve_provider_config(provider)
    worktree_path = setup_worktree(session, session_id)

    {:ok, graph} = CodingLoop.build()

    initial_state =
      CodingLoop.initial_state(%{
        session_id: session_id,
        provider_config: provider_config,
        agent_config: agent,
        worktree_path: worktree_path
      })

    ctx = %{
      provider: provider,
      model: agent[:model] || session.model,
      project_path: session.project.path,
      project_id: to_string(session.project_id)
    }

    {:ok, runner_pid} =
      Runner.start_link(graph: graph, state: initial_state, ctx: ctx, run_id: session_id)

    Synapsis.Memory.Writer.subscribe_session(session_id)

    {session, agent, provider_config, runner_pid, worktree_path}
  end

  defp setup_worktree(session, session_id) do
    if Synapsis.Git.is_repo?(session.project.path) do
      case WorkspaceManager.setup(session.project.path, session_id) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end
  end
end
