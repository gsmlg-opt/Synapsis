defmodule Synapsis.Agent.SessionBridge do
  @moduledoc """
  Bridges agent orchestration with CodingLoop sessions.
  """

  require Logger

  alias Synapsis.Agent.Events.{RunEvent, TerminalWaiter}
  alias Synapsis.Sessions

  @type spawn_opts :: %{
          optional(:provider) => String.t(),
          optional(:model) => String.t(),
          optional(:agent) => String.t(),
          optional(:context) => String.t(),
          optional(:notify_pid) => pid(),
          optional(:notify_ref) => String.t(),
          optional(:timeout_ms) => non_neg_integer()
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
         :ok <- maybe_subscribe_completion(session.id, opts),
         :ok <- maybe_send_message(session.id, initial_message) do
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

  defp maybe_subscribe_completion(session_id, %{notify_pid: pid, notify_ref: ref} = opts)
       when is_pid(pid) do
    timeout_ms = Map.get(opts, :timeout_ms, :timer.minutes(30))
    caller = self()
    ready_ref = make_ref()

    # Subscribe and receive in the *same* Task process. Confirm subscription to
    # the caller before send_message so completion cannot race the watcher.
    {:ok, _task} =
      Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
        topic = "session:#{session_id}"
        :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)
        send(caller, {:session_bridge_watching, ready_ref})

        try do
          deadline = System.monotonic_time(:millisecond) + timeout_ms

          outcome =
            await_already_subscribed(session_id, deadline)

          case outcome do
            {:completed, _} ->
              send(pid, {:coding_session_completed, ref, session_id})

            {:failed, _} ->
              send(pid, {:coding_session_failed, ref, session_id})

            {:cancelled, _} ->
              send(pid, {:coding_session_failed, ref, session_id})

            {:timed_out, _} ->
              send(pid, {:coding_session_failed, ref, session_id})

            {:waiter_timeout, _} ->
              send(pid, {:coding_session_timeout, ref, session_id})
          end
        after
          Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
        end
      end)

    receive do
      {:session_bridge_watching, ^ready_ref} -> :ok
    after
      5_000 -> {:error, :completion_watch_failed}
    end
  end

  defp maybe_subscribe_completion(_session_id, _opts), do: :ok

  defp await_already_subscribed(session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:waiter_timeout, "timed out waiting for session #{session_id}"}
    else
      receive do
        {:run_event, %RunEvent{} = event} ->
          if TerminalWaiter.matches?(event, session_id) do
            {TerminalWaiter.classify(event), event}
          else
            await_already_subscribed(session_id, deadline)
          end

        _other ->
          await_already_subscribed(session_id, deadline)
      after
        remaining ->
          {:waiter_timeout, "timed out waiting for session #{session_id}"}
      end
    end
  end

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
