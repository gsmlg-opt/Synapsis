defmodule Synapsis.Agent.Heartbeat.Worker do
  @moduledoc """
  Oban worker for heartbeat execution (AI-6).

  Runs scheduled agent invocations in isolated sessions.
  Results are optionally written to workspace and user notified via PubSub.
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
        execute_heartbeat(config)
    end
  end

  defp execute_heartbeat(%HeartbeatConfig{} = config) do
    Logger.info("heartbeat_executing",
      name: config.name,
      heartbeat_id: config.id
    )

    # For now, write the heartbeat prompt as a workspace document
    # Full agent session integration will be added when the session system
    # supports programmatic invocation
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    result_content = """
    # Heartbeat: #{config.name}
    **Executed at:** #{timestamp}
    **Prompt:** #{config.prompt}
    **Status:** Executed (agent integration pending)
    """

    # Write latest result
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
           executed_at: timestamp
         }}
      )
    end

    Logger.info("heartbeat_completed",
      name: config.name,
      heartbeat_id: config.id
    )

    :ok
  rescue
    error ->
      Logger.error("heartbeat_failed",
        name: config.name,
        heartbeat_id: config.id,
        error: Exception.message(error)
      )

      {:error, Exception.message(error)}
  end
end
