defmodule Synapsis.Session.Worker.Boot do
  @moduledoc "Handles Worker initialization: session loading, graph creation, Runner start."

  alias Synapsis.{Repo, Session}
  alias Synapsis.Session.Worker.Config
  alias Synapsis.Agent.Runtime.Runner
  alias Synapsis.Agent.Graphs.CodingLoop

  @transient_statuses ~w(streaming tool_executing)

  def load_and_boot(session_id, opts \\ []) do
    case Repo.get(Session, session_id) do
      nil ->
        {:stop, {:error, :session_not_found}}

      session ->
        boot(reset_transient_status(session), session_id, opts)
    end
  end

  defp reset_transient_status(%Session{status: status} = session)
       when status in @transient_statuses do
    case session |> Session.status_changeset("idle") |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> session
    end
  end

  defp reset_transient_status(session), do: session

  defp boot(session, session_id, opts) do
    Process.flag(:trap_exit, true)

    graph_module = Keyword.get(opts, :graph_module, CodingLoop)
    agent = Config.resolve_agent(session)
    provider = agent[:provider] || session.provider
    provider_config = Config.resolve_provider_config(provider)
    workspace_path = normalize_workspace_path(agent[:workspace_path])

    with {:ok, workspace_path} <- ensure_workspace_path(workspace_path),
         {:ok, graph} <- graph_module.build() do
      initial_state =
        graph_module.initial_state(%{
          session_id: session_id,
          provider_config: provider_config,
          agent_config: agent
        })

      ctx = %{
        provider: provider,
        model: agent[:model] || session.model,
        project_path: workspace_path,
        agent_id: session.agent || agent[:name] || "main"
      }

      case Runner.start_link(graph: graph, state: initial_state, ctx: ctx, run_id: session_id) do
        {:ok, runner_pid} ->
          Synapsis.Memory.Writer.subscribe_session(session_id)
          {session, agent, provider_config, runner_pid, workspace_path}

        {:error, reason} ->
          {:stop, {:runner_start_failed, reason}}
      end
    else
      {:error, {:workspace_unavailable, _path, _reason} = reason} ->
        {:stop, reason}

      {:error, reason} ->
        {:stop, {:graph_build_failed, reason}}
    end
  end

  defp normalize_workspace_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp normalize_workspace_path(_), do: File.cwd!()

  @doc false
  def ensure_workspace_path(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:workspace_unavailable, path, reason}}
    end
  end
end
