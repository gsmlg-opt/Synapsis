defmodule Synapsis.Agent.SessionBridge do
  @moduledoc """
  Bridges agent orchestration with CodingLoop sessions.
  """

  require Logger

  alias Synapsis.Sessions

  @type spawn_opts :: %{
          optional(:provider) => String.t(),
          optional(:model) => String.t(),
          optional(:agent) => String.t(),
          optional(:context) => String.t(),
          optional(:notify_pid) => pid(),
          optional(:notify_ref) => String.t()
        }

  @doc """
  Spawns a coding session for an agent, starts the Worker/CodingLoop,
  and optionally sends the initial message.

  Returns `{:ok, session_id}` on success.
  """
  @spec spawn_coding_session(String.t(), String.t() | nil, spawn_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_coding_session(agent_name, initial_message, opts \\ %{}) do
    with {:ok, session} <- create_session(agent_name, opts),
         :ok <- maybe_send_message(session.id, initial_message),
         :ok <- maybe_subscribe_completion(session.id, opts) do
      Logger.info("coding_session_spawned",
        agent: session.agent,
        session_id: session.id
      )

      {:ok, session.id}
    end
  end

  @doc """
  Builds context string for a spawned session from an agent workspace.
  """
  @spec build_spawn_context(String.t(), map()) :: String.t()
  def build_spawn_context(workspace_path, opts \\ %{}) do
    sections = []

    sections =
      case build_file_tree(workspace_path) do
        nil -> sections
        tree -> sections ++ ["## Workspace Files\n```\n#{tree}\n```"]
      end

    sections =
      case build_memory_context(opts) do
        nil -> sections
        mem -> sections ++ ["## Relevant Memory\n#{mem}"]
      end

    case sections do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # -- Private --

  defp create_session(agent_name, opts) do
    attrs = %{
      provider: opts[:provider] || "anthropic",
      model: opts[:model] || Synapsis.Providers.default_model(opts[:provider] || "anthropic"),
      agent: opts[:agent] || agent_name || "main"
    }

    Sessions.create(attrs.agent, attrs)
  end

  defp maybe_send_message(_session_id, nil), do: :ok

  defp maybe_send_message(session_id, message) when is_binary(message) do
    Synapsis.Session.Worker.send_message(session_id, message)
  end

  defp maybe_subscribe_completion(session_id, %{notify_pid: pid, notify_ref: ref})
       when is_pid(pid) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

    Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
      receive do
        {"session_status", %{status: "idle"}} ->
          send(pid, {:coding_session_completed, ref, session_id})

        {"error", _} ->
          send(pid, {:coding_session_failed, ref, session_id})
      after
        :timer.minutes(30) ->
          send(pid, {:coding_session_timeout, ref, session_id})
      end
    end)

    :ok
  end

  defp maybe_subscribe_completion(_session_id, _opts), do: :ok

  defp build_file_tree(project_path) do
    if File.dir?(project_path) do
      lines =
        list_files_recursive(project_path, project_path, 3)
        |> Enum.take(50)
        |> Enum.join("\n")

      if lines == "", do: nil, else: lines
    end
  end

  defp list_files_recursive(_base, _dir, 0), do: []

  defp list_files_recursive(base, dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          rel = Path.relative_to(full, base)

          if File.dir?(full) do
            [rel | list_files_recursive(base, full, depth - 1)]
          else
            [rel]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp build_memory_context(opts) do
    agent_id = opts[:agent_id] || opts[:agent]

    if agent_id do
      context = Synapsis.Memory.ContextBuilder.build(%{agent_id: agent_id, agent_scope: :agent})
      if context == "", do: nil, else: context
    end
  rescue
    _e in [RuntimeError, UndefinedFunctionError, ArgumentError] -> nil
  end
end
