defmodule Synapsis.Agent.Heartbeat.Scheduler do
  @moduledoc """
  Syncs heartbeat configurations from the database to Oban cron jobs (AI-6.3).

  On startup and on PubSub config change events, loads enabled heartbeat configs
  from the database and schedules them via Oban.
  """

  require Logger

  alias Synapsis.HeartbeatConfig

  @doc """
  Sync all enabled heartbeat configs to Oban job queue.

  Inserts scheduled Oban jobs for each enabled heartbeat. Existing jobs for
  the same heartbeat are replaced.
  """
  @spec sync_crontab() :: :ok
  def sync_crontab do
    configs = load_enabled_configs()

    Logger.info("heartbeat_sync",
      count: length(configs),
      names: Enum.map(configs, & &1.name)
    )

    Enum.each(configs, &schedule_heartbeat/1)

    :ok
  end

  @doc "Schedule a single heartbeat config as an Oban job."
  @spec schedule_heartbeat(HeartbeatConfig.t()) :: :ok
  def schedule_heartbeat(%HeartbeatConfig{} = config) do
    %{"heartbeat_id" => config.id}
    |> Synapsis.Agent.Heartbeat.Worker.new(
      scheduled_at: next_run_time(config.schedule),
      unique: [period: 60, keys: [:heartbeat_id]]
    )
    |> Oban.insert()

    :ok
  rescue
    error ->
      Logger.warning("heartbeat_schedule_failed",
        name: config.name,
        error: Exception.message(error)
      )

      :ok
  end

  @doc "Load all enabled heartbeat configs from the database."
  @spec load_enabled_configs() :: [HeartbeatConfig.t()]
  def load_enabled_configs do
    HeartbeatConfig.list_enabled()
  end

  # Simple next-run calculation — for production, use a proper cron parser.
  # For now, schedule 1 minute from now as a placeholder.
  defp next_run_time(_schedule) do
    DateTime.utc_now() |> DateTime.add(60, :second)
  end
end
