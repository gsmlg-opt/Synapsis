defmodule Synapsis.Session.Worker.Boot do
  @moduledoc "Handles Worker initialization: session loading, graph creation, Runner start."

  alias Synapsis.{Repo, Session}
  alias Synapsis.Session.WorkspaceManager
  alias Synapsis.Session.Worker.Config
  alias Synapsis.Agent.Runtime.Runner
  alias Synapsis.Agent.Graphs.CodingLoop

  def load_and_boot(session_id, opts \\ []) do
    case Repo.get(Session, session_id) do
      nil -> {:stop, {:error, :session_not_found}}
      session -> boot(Repo.preload(session, :project), session_id, opts)
    end
  end

  defp boot(session, session_id, opts) do
    Process.flag(:trap_exit, true)

    graph_module = Keyword.get(opts, :graph_module, CodingLoop)
    agent = Config.resolve_agent(session)
    provider = agent[:provider] || session.provider
    provider_config = Config.resolve_provider_config(provider)
    project_path = normalize_project_path(session.project && session.project.path)
    worktree_path = setup_worktree(project_path, session_id)

    with {:ok, graph} <- graph_module.build() do
      initial_state =
        graph_module.initial_state(%{
          session_id: session_id,
          provider_config: provider_config,
          agent_config: agent,
          worktree_path: worktree_path
        })

      ctx = %{
        provider: provider,
        model: agent[:model] || session.model,
        project_path: project_path,
        project_id: to_string(session.project_id)
      }

      case Runner.start_link(graph: graph, state: initial_state, ctx: ctx, run_id: session_id) do
        {:ok, runner_pid} ->
          Synapsis.Memory.Writer.subscribe_session(session_id)
          {session, agent, provider_config, runner_pid, worktree_path, project_path}

        {:error, reason} ->
          {:stop, {:runner_start_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:graph_build_failed, reason}}
    end
  end

  # "__global__" is a sentinel for sessions not tied to a specific project directory.
  # Normalize it to the actual CWD so tools resolve relative paths correctly.
  defp normalize_project_path(nil), do: File.cwd!()
  defp normalize_project_path("__global__"), do: File.cwd!()
  defp normalize_project_path(path), do: path

  defp setup_worktree(project_path, session_id) do
    if Synapsis.Git.is_repo?(project_path) do
      case WorkspaceManager.setup(project_path, session_id) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end
  end
end
