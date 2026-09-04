defmodule Synapsis.Agent.Heartbeat.Delivery do
  @moduledoc """
  Optional report delivery for heartbeat runs.

  Execution outcome is already persisted on `AgentRun`. Delivery failures must
  never rewrite that execution status.
  """

  alias Synapsis.AgentRun
  alias Synapsis.Workspace
  require Logger

  @spec deliver(AgentRun.t(), map()) :: :ok | {:error, term()}
  def deliver(%AgentRun{} = run, config) when is_map(config) do
    timestamp = DateTime.to_iso8601(run.finished_at || DateTime.utc_now())
    content = format_report(run, config, timestamp)

    with :ok <- write_results(config, timestamp, content) do
      maybe_notify(config, run, timestamp, content)
      :ok
    end
  rescue
    error ->
      Logger.warning("heartbeat_delivery_failed",
        run_id: run.id,
        reason: Exception.message(error)
      )

      {:error, Exception.message(error)}
  end

  defp write_results(config, timestamp, content) do
    name = config[:name] || config["name"] || "unknown"
    latest_path = "/global/heartbeats/#{name}/latest.md"

    with :ok <-
           normalize_write(
             Workspace.write(latest_path, content, %{author: "system", lifecycle: :scratch})
           ) do
      if config[:keep_history] || config["keep_history"] do
        history_path = "/global/heartbeats/#{name}/history/#{timestamp}.md"

        _ =
          normalize_write(
            Workspace.write(history_path, content, %{author: "system", lifecycle: :draft})
          )
      end

      :ok
    end
  end

  defp normalize_write(:ok), do: :ok
  defp normalize_write({:ok, _}), do: :ok
  defp normalize_write({:error, reason}), do: {:error, reason}
  defp normalize_write(other), do: {:error, other}

  defp maybe_notify(config, %AgentRun{} = run, timestamp, content) do
    if config[:notify_user] || config["notify_user"] do
      event =
        case run.status do
          "completed" -> :heartbeat_completed
          _ -> :heartbeat_failed
        end

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "heartbeat:notifications",
        {event, config[:id] || config["id"] || run.heartbeat_id,
         %{
           name: config[:name] || config["name"],
           run_id: run.id,
           executed_at: timestamp,
           result: content,
           execution_status: run.status
         }}
      )
    end

    :ok
  end

  defp format_report(%AgentRun{status: "completed"} = run, config, timestamp) do
    name = config[:name] || config["name"] || "heartbeat"
    summary = run.summary || session_summary(run) || "(no summary)"

    """
    # Heartbeat: #{name}
    **Executed at:** #{timestamp}
    **Status:** Completed
    **Run ID:** #{run.id}

    ## Result

    #{summary}
    """
  end

  defp format_report(%AgentRun{} = run, config, timestamp) do
    name = config[:name] || config["name"] || "heartbeat"
    error = run.error || run.status

    """
    # Heartbeat: #{name}
    **Executed at:** #{timestamp}
    **Status:** #{run.status}
    **Run ID:** #{run.id}
    **Error:** #{error}
    """
  end

  defp session_summary(%AgentRun{session_id: session_id}) when is_binary(session_id) do
    messages = Synapsis.Sessions.get_messages(session_id)

    messages
    |> Enum.filter(fn msg -> msg.role == :assistant or msg.role == "assistant" end)
    |> List.last()
    |> case do
      nil -> nil
      msg -> extract_text(msg)
    end
  rescue
    _ -> nil
  end

  defp session_summary(_), do: nil

  defp extract_text(%Synapsis.Message{parts: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %Synapsis.Part.Text{} -> true
      _ -> false
    end)
    |> Enum.map(fn %Synapsis.Part.Text{content: content} -> content end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: nil
end
