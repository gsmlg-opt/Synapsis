defmodule Synapsis.Agent.SessionBridge do
  @moduledoc """
  Bridges multi-agent system (GlobalAssistant/ProjectAssistant) with
  CodingLoop sessions. Handles spawning sessions, injecting context,
  and monitoring completion.
  """

  # LSP.Manager lives in synapsis_lsp (optional dependency)
  @compile {:no_warn_undefined, Synapsis.LSP.Manager}

  require Logger

  alias Synapsis.{Repo, Session, Project}
  alias Synapsis.Session.DynamicSupervisor, as: SessionDynSup

  @type spawn_opts :: %{
          optional(:provider) => String.t(),
          optional(:model) => String.t(),
          optional(:agent) => String.t(),
          optional(:context) => String.t(),
          optional(:notify_pid) => pid(),
          optional(:notify_ref) => String.t()
        }

  @doc """
  Spawns a coding session for a project, starts the Worker/CodingLoop,
  and optionally sends the initial message.

  Returns `{:ok, session_id}` on success.
  """
  @spec spawn_coding_session(String.t(), String.t() | nil, spawn_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_coding_session(project_id, initial_message, opts \\ %{}) do
    with {:ok, project} <- fetch_project(project_id),
         {:ok, session} <- create_session(project, opts),
         {:ok, _sup} <- start_session(session.id),
         :ok <- maybe_send_message(session.id, initial_message),
         :ok <- maybe_subscribe_completion(session.id, opts) do
      Logger.info("coding_session_spawned",
        project_id: project_id,
        session_id: session.id
      )

      {:ok, session.id}
    end
  end

  @doc """
  Builds context string for a spawned session from project state.
  Includes file tree, recent git log, active diagnostics, and memory.
  """
  @spec build_spawn_context(String.t(), map()) :: String.t()
  def build_spawn_context(project_path, opts \\ %{}) do
    sections = []

    sections =
      case build_file_tree(project_path) do
        nil -> sections
        tree -> sections ++ ["## Project Files\n```\n#{tree}\n```"]
      end

    sections =
      case build_git_log(project_path) do
        nil -> sections
        log -> sections ++ ["## Recent Git History\n```\n#{log}\n```"]
      end

    sections =
      case build_diagnostics(opts[:project_id]) do
        nil -> sections
        diag -> sections ++ ["## Active Diagnostics\n#{diag}"]
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

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  defp create_session(project, opts) do
    attrs = %{
      project_id: project.id,
      provider: opts[:provider] || "anthropic",
      model: opts[:model] || Synapsis.Providers.default_model(opts[:provider] || "anthropic"),
      agent: opts[:agent] || "build"
    }

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  defp start_session(session_id) do
    SessionDynSup.start_session(session_id)
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
      case run_command("find", [project_path, "-maxdepth", "3", "-not", "-path", "*/.*"]) do
        {:ok, output} ->
          lines =
            output
            |> String.split("\n", trim: true)
            |> Enum.take(50)
            |> Enum.map(&String.replace(&1, project_path <> "/", ""))
            |> Enum.join("\n")

          if lines == "", do: nil, else: lines

        {:error, _} ->
          nil
      end
    end
  end

  defp build_git_log(project_path) do
    if Synapsis.Git.is_repo?(project_path) do
      case run_command("git", ["-C", project_path, "log", "--oneline", "-10"]) do
        {:ok, output} -> if output == "", do: nil, else: String.trim(output)
        {:error, _} -> nil
      end
    end
  end

  defp run_command(cmd, args) do
    full_cmd = Enum.join([cmd | args], " ")

    port =
      Port.open({:spawn, full_cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096}
      ])

    collect_port_output(port, [])
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        collect_port_output(port, [line | acc])

      {^port, {:data, {:noeol, line}}} ->
        collect_port_output(port, [line | acc])

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> Enum.join("\n")}

      {^port, {:exit_status, _code}} ->
        {:error, acc |> Enum.reverse() |> Enum.join("\n")}
    after
      10_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp build_diagnostics(nil), do: nil

  defp build_diagnostics(project_id) do
    case Synapsis.LSP.Manager.get_diagnostics(project_id) do
      {:ok, diagnostics} when diagnostics != [] ->
        diagnostics
        |> Enum.take(10)
        |> Enum.map(fn d -> "- #{d.file}:#{d.line}: #{d.message}" end)
        |> Enum.join("\n")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp build_memory_context(opts) do
    project_id = opts[:project_id]

    if project_id do
      context = Synapsis.Memory.ContextBuilder.build(%{project_id: project_id})
      if context == "", do: nil, else: context
    end
  rescue
    _ -> nil
  end
end
