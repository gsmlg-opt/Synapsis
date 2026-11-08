defmodule Synapsis.Agent.Heartbeat.CronSchedule do
  @moduledoc """
  Resolve cron wall times in an explicit timezone to strictly future UTC instants.

  Repeated wall times use their first occurrence only. Nonexistent wall times are
  skipped and the cron expression is matched again after the timezone gap.
  """

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @time_zone_database Tzdata.TimeZoneDatabase
  @max_candidates 10_000

  @spec normalize_timezone(term()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def normalize_timezone(nil), do: {:ok, "Etc/UTC"}

  def normalize_timezone(timezone) when is_binary(timezone) do
    case String.trim(timezone) do
      timezone when timezone in ["", "UTC", "utc", "Etc/UTC"] -> {:ok, "Etc/UTC"}
      timezone -> {:ok, timezone}
    end
  end

  def normalize_timezone(_timezone), do: {:error, :invalid_timezone}

  @spec next_after(String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_after(cron, timezone, %DateTime{} = now) when is_binary(cron) do
    with {:ok, timezone} <- normalize_timezone(timezone),
         {:ok, expression} <- Parser.parse(cron),
         :ok <- supported_expression(expression),
         {:ok, local_now} <- DateTime.shift_zone(now, timezone, @time_zone_database) do
      cursor = local_now |> DateTime.to_naive() |> NaiveDateTime.add(1, :microsecond)
      find_next(expression, timezone, now, cursor, @max_candidates)
    end
  end

  def next_after(_cron, _timezone, _now), do: {:error, :invalid_schedule_input}

  defp supported_expression(%CronExpression{reboot: true}),
    do: {:error, :unsupported_schedule}

  defp supported_expression(%CronExpression{}), do: :ok

  defp find_next(_expression, _timezone, _now, _cursor, 0),
    do: {:error, :cron_search_exhausted}

  defp find_next(expression, timezone, now, cursor, attempts) do
    with {:ok, candidate} <- Scheduler.get_next_run_date(expression, cursor) do
      case wall_to_utc(candidate, timezone) do
        {:ok, instant} ->
          if DateTime.compare(instant, now) == :gt do
            {:ok, instant}
          else
            cursor = NaiveDateTime.add(candidate, 1, :microsecond)
            find_next(expression, timezone, now, cursor, attempts - 1)
          end

        {:gap, cursor} ->
          find_next(expression, timezone, now, cursor, attempts - 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp wall_to_utc(candidate, timezone) do
    case DateTime.from_naive(candidate, timezone, @time_zone_database) do
      {:ok, datetime} ->
        DateTime.shift_zone(datetime, "Etc/UTC", @time_zone_database)

      {:ambiguous, first, second} ->
        earliest = if DateTime.compare(first, second) == :gt, do: second, else: first
        DateTime.shift_zone(earliest, "Etc/UTC", @time_zone_database)

      {:gap, _before_gap, after_gap} ->
        {:gap, DateTime.to_naive(after_gap)}

      {:error, _reason} = error ->
        error
    end
  end
end
