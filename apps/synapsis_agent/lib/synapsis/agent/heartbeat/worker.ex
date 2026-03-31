defmodule Synapsis.Agent.Heartbeat.Worker do
  @moduledoc """
  Oban worker for heartbeat execution (AI-6).

  Runs scheduled agent invocations in isolated sessions.
  Results are written to workspace and user notified via PubSub.
  After execution, the worker reschedules itself for the next cron window.
  """
  use Oban.Worker,
    queue: :heartbeat,
    max_attempts: 3,
    priority: 3

  alias Synapsis.HeartbeatConfig
  alias Synapsis.Heartbeats
  alias Synapsis.Workspace
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"heartbeat_id" => heartbeat_id}}) do
    case Heartbeats.get(heartbeat_id) do
      nil ->
        Logger.warning("heartbeat_config_not_found", heartbeat_id: heartbeat_id)
        {:error, :config_not_found}

      %HeartbeatConfig{enabled: false} ->
        Logger.info("heartbeat_disabled", heartbeat_id: heartbeat_id)
        :ok

      config ->
        case execute_heartbeat(config) do
          :ok ->
            case Synapsis.Agent.Heartbeat.Scheduler.schedule_heartbeat(config) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning("heartbeat_reschedule_failed",
                  heartbeat_id: heartbeat_id,
                  reason: inspect(reason)
                )

                :ok
            end

          {:error, _} = error ->
            Logger.warning("heartbeat_skipping_reschedule",
              heartbeat_id: heartbeat_id,
              reason: "execution failed"
            )

            error
        end
    end
  end

  defp execute_heartbeat(%HeartbeatConfig{} = config) do
    Logger.info("heartbeat_executing",
      name: config.name,
      heartbeat_id: config.id
    )

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Create a headless session for the heartbeat
    result_content = run_heartbeat_session(config, timestamp)

    # Write latest result to workspace
    latest_path = "/global/heartbeats/#{config.name}/latest.md"
    Workspace.write(latest_path, result_content, %{author: "system", lifecycle: :scratch})

    # Write history entry if configured
    if config.keep_history do
      history_path = "/global/heartbeats/#{config.name}/history/#{timestamp}.md"
      Workspace.write(history_path, result_content, %{author: "system", lifecycle: :draft})
    end

    # Notify user if configured
    if config.notify_user do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "heartbeat:notifications",
        {:heartbeat_completed, config.id,
         %{
           name: config.name,
           executed_at: timestamp,
           result: result_content
         }}
      )
    end

    Logger.info("heartbeat_completed",
      name: config.name,
      heartbeat_id: config.id
    )

    :ok
  rescue
    e ->
      Logger.error("heartbeat_failed",
        name: config.name,
        heartbeat_id: config.id,
        error: Exception.message(e),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, Exception.message(e)}
  end

  # Run a headless agent session with the heartbeat prompt.
  # Uses the default project path "~" for global heartbeats, or the
  # project path for project-scoped heartbeats.
  defp run_heartbeat_session(%HeartbeatConfig{} = config, timestamp) do
    project_path = resolve_project_path(config)

    case create_heartbeat_session(project_path, config) do
      {:ok, session} ->
        case Synapsis.Sessions.send_message(session.id, config.prompt) do
          :ok ->
            # Wait for the agent to finish (with timeout)
            result = await_session_completion(session.id)

            # Clean up the ephemeral session
            Synapsis.Sessions.delete(session.id)

            format_result(config, timestamp, result)

          {:error, _reason} ->
            Synapsis.Sessions.delete(session.id)
            format_error(config, timestamp, "send_message failed")
        end

      {:error, _reason} ->
        format_error(config, timestamp, "session creation failed")
    end
  end

  defp resolve_project_path(%HeartbeatConfig{agent_type: :project, project_id: pid})
       when is_binary(pid) do
    case Synapsis.Projects.get(pid) do
      {:ok, %Synapsis.Project{path: path}} -> path
      {:error, _} -> System.user_home() || "/"
    end
  end

  defp resolve_project_path(_config) do
    System.user_home() || "/"
  end

  defp create_heartbeat_session(project_path, config) do
    Synapsis.Sessions.create(project_path, %{
      title: "Heartbeat: #{config.name}",
      agent: "build",
      metadata: %{type: :heartbeat, heartbeat_id: config.id, heartbeat_name: config.name}
    })
  end

  # Wait for session completion via PubSub subscription instead of polling.
  defp await_session_completion(session_id, timeout_ms \\ 120_000) do
    topic = "session:#{session_id}"
    Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

    result =
      receive do
        {:session_completed, ^session_id, _result} ->
          fetch_last_assistant_response(session_id)

        {:session_error, ^session_id, _reason} ->
          {:timeout, "session error"}
      after
        timeout_ms ->
          # Fallback: check messages directly before declaring timeout
          case fetch_last_assistant_response(session_id) do
            {:ok, _} = ok -> ok
            _ -> {:timeout, "heartbeat session timed out after #{div(timeout_ms, 1_000)}s"}
          end
      end

    Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
    flush_mailbox(session_id)
    result
  end

  # Drain any remaining PubSub messages for this session from the process mailbox
  # to prevent mailbox pollution in the Oban worker process.
  defp flush_mailbox(session_id) do
    receive do
      {_, ^session_id, _} -> flush_mailbox(session_id)
    after
      0 -> :ok
    end
  end

  defp fetch_last_assistant_response(session_id) do
    messages = Synapsis.Sessions.get_messages(session_id)

    messages
    |> Enum.filter(fn msg -> msg.role == :assistant end)
    |> List.last()
    |> case do
      nil -> {:timeout, "no assistant response"}
      msg -> {:ok, extract_text_content(msg)}
    end
  end

  defp extract_text_content(%Synapsis.Message{parts: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %Synapsis.Part.Text{} -> true
      _ -> false
    end)
    |> Enum.map(fn %Synapsis.Part.Text{content: content} -> content end)
    |> Enum.join("\n")
  end

  defp extract_text_content(_), do: "(no content)"

  defp format_result(config, timestamp, {:ok, content}) do
    """
    # Heartbeat: #{config.name}
    **Executed at:** #{timestamp}
    **Status:** Completed

    ## Result

    #{content}
    """
  end

  defp format_result(config, timestamp, {:timeout, reason}) do
    format_error(config, timestamp, reason)
  end

  defp format_error(config, timestamp, error) do
    """
    # Heartbeat: #{config.name}
    **Executed at:** #{timestamp}
    **Status:** Error
    **Error:** #{error}
    """
  end
end
