defmodule Synapsis.Agent.Heartbeat.Worker do
  @moduledoc """
  Heartbeat execution — called by `LocalScheduler` as a supervised Task.

  Runs scheduled agent invocations in isolated sessions.
  Results are written to workspace and user notified via PubSub.
  """

  alias Synapsis.Agent.Events.TerminalWaiter
  alias Synapsis.Workspace
  require Logger

  @doc "Execute a heartbeat config map (from Config.Store or Ecto, same shape)."
  @spec execute(map()) :: :ok | {:error, term()}
  def execute(config) do
    case Map.get(config, :enabled, true) do
      false ->
        Logger.info("heartbeat_disabled", name: config.name)
        :ok

      _ ->
        case execute_heartbeat(config) do
          :ok -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # Legacy entry-point used by old Oban scheduler — keeps callers compiling.
  @doc false
  def perform_by_id(heartbeat_id) do
    case Synapsis.Heartbeats.get(heartbeat_id) do
      nil ->
        Logger.warning("heartbeat_config_not_found", heartbeat_id: heartbeat_id)
        {:error, :config_not_found}

      %{enabled: false} ->
        Logger.info("heartbeat_disabled", heartbeat_id: heartbeat_id)
        :ok

      config ->
        execute_heartbeat(config)
    end
  end

  defp execute_heartbeat(config) do
    Logger.info("heartbeat_executing",
      name: config.name,
      heartbeat_id: config.id
    )

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    case run_heartbeat_session(config, timestamp) do
      {:ok, result_content} ->
        write_results(config, timestamp, result_content)
        maybe_notify(config, timestamp, result_content, :completed)

        Logger.info("heartbeat_completed",
          name: config.name,
          heartbeat_id: config.id
        )

        :ok

      {:error, reason, result_content} ->
        write_results(config, timestamp, result_content)
        maybe_notify(config, timestamp, result_content, :failed)

        Logger.error("heartbeat_execution_failed",
          name: config.name,
          heartbeat_id: config.id,
          error: reason
        )

        {:error, reason}
    end
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

  defp write_results(config, timestamp, result_content) do
    latest_path = "/global/heartbeats/#{config.name}/latest.md"
    Workspace.write(latest_path, result_content, %{author: "system", lifecycle: :scratch})

    if config.keep_history do
      history_path = "/global/heartbeats/#{config.name}/history/#{timestamp}.md"
      Workspace.write(history_path, result_content, %{author: "system", lifecycle: :draft})
    end
  end

  defp maybe_notify(config, timestamp, result_content, execution_status) do
    if config.notify_user do
      event =
        case execution_status do
          :completed -> :heartbeat_completed
          :failed -> :heartbeat_failed
        end

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "heartbeat:notifications",
        {event, config.id,
         %{
           name: config.name,
           executed_at: timestamp,
           result: result_content,
           execution_status: execution_status
         }}
      )
    end
  end

  defp run_heartbeat_session(config, timestamp) do
    case create_heartbeat_session(config) do
      {:ok, session} ->
        # Subscribe before send_message so completion cannot race the waiter.
        watch =
          TerminalWaiter.await_after(session.id, [], fn ->
            Synapsis.Sessions.send_message(session.id, config.prompt)
          end)

        result = interpret_watch(config, timestamp, session.id, watch)
        Synapsis.Sessions.delete(session.id)
        result

      {:error, reason} ->
        {:error, "session creation failed: #{inspect(reason)}",
         format_error(config, timestamp, "session creation failed")}
    end
  end

  defp create_heartbeat_session(config) do
    agent_name = config.agent_name || "main"

    Synapsis.Sessions.create(agent_name, %{
      title: "Heartbeat: #{config.name}",
      agent: agent_name,
      metadata: %{type: :heartbeat, heartbeat_id: config.id, heartbeat_name: config.name}
    })
  end

  # Typed terminals are authoritative. Transcript is only read after success.
  defp interpret_watch(config, timestamp, session_id, {:completed, _event}) do
    content =
      case fetch_last_assistant_response(session_id) do
        {:ok, text} -> text
        {:missing, placeholder} -> placeholder
      end

    {:ok, format_success(config, timestamp, content)}
  end

  defp interpret_watch(config, timestamp, _session_id, {:failed, event}) do
    reason = event.payload["message"] || "session failed"
    {:error, reason, format_error(config, timestamp, reason)}
  end

  defp interpret_watch(config, timestamp, _session_id, {:cancelled, event}) do
    reason = event.payload["message"] || "session cancelled"
    {:error, reason, format_error(config, timestamp, reason)}
  end

  defp interpret_watch(config, timestamp, _session_id, {:timed_out, event}) do
    reason = event.payload["message"] || "session timed out"
    {:error, reason, format_error(config, timestamp, reason)}
  end

  defp interpret_watch(config, timestamp, _session_id, {:waiter_timeout, reason}) do
    {:error, reason, format_error(config, timestamp, reason)}
  end

  defp interpret_watch(config, timestamp, _session_id, {:trigger_error, reason}) do
    message = "send_message failed: #{inspect(reason)}"
    {:error, message, format_error(config, timestamp, message)}
  end

  defp fetch_last_assistant_response(session_id) do
    messages = Synapsis.Sessions.get_messages(session_id)

    messages
    |> Enum.filter(fn msg -> msg.role == :assistant or msg.role == "assistant" end)
    |> List.last()
    |> case do
      nil -> {:missing, "(no assistant response)"}
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

  defp format_success(config, timestamp, content) do
    """
    # Heartbeat: #{config.name}
    **Executed at:** #{timestamp}
    **Status:** Completed

    ## Result

    #{content}
    """
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
