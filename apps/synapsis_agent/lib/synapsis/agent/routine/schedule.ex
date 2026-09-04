defmodule Synapsis.Agent.Routine.Schedule do
  @moduledoc """
  Cron next-occurrence helpers with UTC keys and DST fold policy.
  """

  alias Synapsis.Agent.Routine.Clock

  @doc """
  Compute the next run instant after `now` for a cron expression.

  `timezone` defaults to Etc/UTC. Non-UTC zones use `DateTime.from_naive/2` when
  a time-zone database is configured; otherwise the cron is evaluated in UTC
  (existing heartbeat behaviour).
  """
  @spec next_after(String.t(), String.t(), DateTime.t() | nil) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_after(cron, timezone \\ "Etc/UTC", now \\ nil)

  def next_after(cron, timezone, nil), do: next_after(cron, timezone, Clock.now())

  def next_after(cron, timezone, %DateTime{} = now) when is_binary(cron) do
    with {:ok, expr} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, local_now} <- to_local_naive(now, timezone),
         {:ok, next_local} <- Crontab.Scheduler.get_next_run_date(expr, local_now),
         {:ok, next_utc} <- local_naive_to_utc(next_local, timezone) do
      {:ok, next_utc}
    end
  end

  @doc "Deterministic occurrence key: `routine_id:scheduled_for_iso8601`."
  @spec occurrence_key(String.t(), DateTime.t()) :: String.t()
  def occurrence_key(routine_id, %DateTime{} = scheduled_for) when is_binary(routine_id) do
    iso = scheduled_for |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    "#{routine_id}:#{iso}"
  end

  @doc """
  Fold ambiguous / gap local times to a single UTC instant.

  Policy (locked by tests):
  - ambiguous (DST fall-back): choose the **earlier** UTC instant
  - gap (DST spring-forward): choose the instant **after** the gap
  """
  @spec fold_local_result(term()) :: {:ok, DateTime.t()} | {:error, term()}
  def fold_local_result({:ok, %DateTime{} = dt}), do: {:ok, dt}

  def fold_local_result({:ambiguous, %DateTime{} = earlier, %DateTime{} = later}) do
    if DateTime.compare(earlier, later) == :lt, do: {:ok, earlier}, else: {:ok, later}
  end

  def fold_local_result({:gap, _before, %DateTime{} = after_gap}), do: {:ok, after_gap}
  def fold_local_result({:error, reason}), do: {:error, reason}
  def fold_local_result(other), do: {:error, other}

  defp to_local_naive(%DateTime{} = now, tz) when tz in ["Etc/UTC", "UTC", "utc"] do
    {:ok, DateTime.to_naive(DateTime.shift_zone!(now, "Etc/UTC"))}
  rescue
    _ -> {:ok, DateTime.to_naive(now)}
  end

  defp to_local_naive(%DateTime{} = now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local} -> {:ok, DateTime.to_naive(local)}
      {:error, _} -> {:ok, DateTime.to_naive(now)}
    end
  end

  defp local_naive_to_utc(%NaiveDateTime{} = local, tz) when tz in ["Etc/UTC", "UTC", "utc"] do
    {:ok, DateTime.from_naive!(local, "Etc/UTC")}
  end

  defp local_naive_to_utc(%NaiveDateTime{} = local, timezone) do
    local
    |> DateTime.from_naive(timezone)
    |> fold_local_result()
  catch
    _, _ ->
      {:ok, DateTime.from_naive!(local, "Etc/UTC")}
  end
end
