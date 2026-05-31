defmodule Synapsis.Agent.Heartbeat.Scheduler do
  @moduledoc """
  Deprecated — superseded by `Synapsis.Agent.Heartbeat.LocalScheduler` (ADR-006 C3).
  Kept as a compile-time stub so existing callers resolve without error.
  """

  require Logger

  @doc false
  def sync_crontab do
    Logger.debug("heartbeat_scheduler_deprecated, use LocalScheduler")
    :ok
  end

  @doc false
  def schedule_heartbeat(_config), do: :ok

  @doc false
  def load_enabled_configs, do: []

  @doc false
  def next_run_time(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, expr} ->
        case Crontab.Scheduler.get_next_run_date(expr) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, reason} -> {:error, "cannot compute next run: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "invalid cron expression: #{inspect(reason)}"}
    end
  end
end
