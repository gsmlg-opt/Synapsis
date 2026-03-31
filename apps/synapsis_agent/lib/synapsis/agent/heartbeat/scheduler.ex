defmodule Synapsis.Agent.Heartbeat.Scheduler do
  @moduledoc """
  Syncs heartbeat configurations from the database to Oban cron jobs (AI-6.3).

  On startup and on PubSub config change events, loads enabled heartbeat configs
  from the database and schedules them via Oban.
  """

  require Logger

  alias Synapsis.HeartbeatConfig
  alias Synapsis.Heartbeats

  @doc """
  Sync all enabled heartbeat configs to Oban job queue.

  Inserts scheduled Oban jobs for each enabled heartbeat. Existing jobs for
  the same heartbeat are replaced via uniqueness constraints.
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
    case next_run_time(config.schedule) do
      {:ok, scheduled_at} ->
        result =
          %{"heartbeat_id" => config.id}
          |> Synapsis.Agent.Heartbeat.Worker.new(
            scheduled_at: scheduled_at,
            unique: [period: 60, keys: [:heartbeat_id]]
          )
          |> Oban.insert()

        case result do
          {:ok, _job} ->
            Logger.info("heartbeat_scheduled",
              name: config.name,
              next_run: DateTime.to_iso8601(scheduled_at)
            )

          {:error, changeset} ->
            Logger.warning("heartbeat_insert_failed",
              name: config.name,
              error: inspect(changeset)
            )
        end

        :ok

      {:error, reason} ->
        Logger.warning("heartbeat_schedule_failed",
          name: config.name,
          error: reason
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("heartbeat_schedule_failed",
        name: config.name,
        error: Exception.message(e)
      )

      :ok
  end

  @doc "Load all enabled heartbeat configs from the database."
  @spec load_enabled_configs() :: [HeartbeatConfig.t()]
  def load_enabled_configs do
    Heartbeats.list_enabled()
  end

  @doc """
  Calculate next run time from a 5-field cron expression.
  Uses Crontab library for parsing and next-run calculation.
  Returns `{:ok, DateTime.t()}` or `{:error, String.t()}`.
  """
  @spec next_run_time(String.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def next_run_time(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, expr} ->
        case Crontab.Scheduler.get_next_run_date(expr) do
          {:ok, naive} ->
            {:ok, DateTime.from_naive!(naive, "Etc/UTC")}

          {:error, reason} ->
            {:error, "cannot compute next run: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "invalid cron expression: #{inspect(reason)}"}
    end
  end
end
