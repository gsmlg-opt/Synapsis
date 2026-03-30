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
  alias Synapsis.Workspace
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"heartbeat_id" => heartbeat_id}}) do
    case HeartbeatConfig.get(heartbeat_id) do
      nil ->
        Logger.warning("heartbeat_config_not_found", heartbeat_id: heartbeat_id)
        {:error, :config_not_found}

      %HeartbeatConfig{enabled: false} ->
        Logger.info("heartbeat_disabled", heartbeat_id: heartbeat_id)
        :ok

      config ->
        result = execute_heartbeat(config)

        # Reschedule for next cron window
        Synapsis.Agent.Heartbeat.Scheduler.schedule_heartbeat(config)

        result
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
    e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError, MatchError] ->
      Logger.error("heartbeat_failed",
        name: config.name,
        heartbeat_id: config.id,
        error: Exception.message(e)
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

          {:error, reason} ->
            Synapsis.Sessions.delete(session.id)
            format_error(config, timestamp, "send_message failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        format_error(config, timestamp, "session creation failed: #{inspect(reason)}")
    end
  end

  defp resolve_project_path(%HeartbeatConfig{agent_type: :project, project_id: pid})
       when is_binary(pid) do
    case Synapsis.Repo.get(Synapsis.Project, pid) do
      %Synapsis.Project{path: path} -> path
      nil -> System.user_home() || "/"
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

  # Poll session messages until we see an assistant response or timeout
  defp await_session_completion(session_id, timeout_ms \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_response(session_id, deadline)
  end

  defp poll_for_response(session_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, "heartbeat session timed out after 120s"}
    else
      messages = Synapsis.Sessions.get_messages(session_id)

      assistant_messages =
        Enum.filter(messages, fn msg -> msg.role == :assistant end)

      case assistant_messages do
        [] ->
          Process.sleep(1_000)
          poll_for_response(session_id, deadline)

        msgs ->
          last = List.last(msgs)
          {:ok, extract_text_content(last)}
      end
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
