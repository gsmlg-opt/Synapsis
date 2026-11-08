defmodule Synapsis.Agent.Heartbeat.Schedule do
  @moduledoc "Pure next-instant calculation; lifecycle ownership stays in LocalScheduler."

  alias Synapsis.Agent.Heartbeat.CronSchedule
  alias Synapsis.RoutineSchedule

  def next_after(schedule, timezone, now), do: next_after(schedule, timezone, now, nil)

  @doc "Compute a future instant using the stable job UUID for explicit cron staggering."
  def next_after(schedule, timezone, %DateTime{} = now, job_id) do
    with {:ok, schedule} <- RoutineSchedule.normalize(schedule) do
      next(schedule, timezone, now, job_id)
    end
  end

  def next_after(_, _, _, _), do: {:error, :invalid_schedule_input}

  defp next(cron, timezone, now, _job_id) when is_binary(cron),
    do: CronSchedule.next_after(cron, timezone, now)

  defp next(%{"kind" => "cron", "expr" => expr} = schedule, timezone, now, job_id) do
    timezone = Map.get(schedule, "tz", timezone)

    with {:ok, offset} <- stagger_offset(job_id, Map.get(schedule, "staggerMs", 0)) do
      if offset == 0 do
        CronSchedule.next_after(expr, timezone, now)
      else
        now_ms = DateTime.to_unix(now, :millisecond)
        staggered_next(expr, timezone, now_ms, max(0, now_ms - offset), offset, 4)
      end
    end
  end

  defp next(%{"kind" => "at", "at" => at}, _timezone, now, _job_id) do
    with {:ok, instant} <- RoutineSchedule.parse_at(at) do
      if DateTime.compare(instant, now) == :gt, do: {:ok, instant}, else: :none
    end
  end

  defp next(%{"kind" => "every", "everyMs" => period} = schedule, _timezone, now, _job_id) do
    now_ms = DateTime.to_unix(now, :millisecond)
    anchor = Map.get(schedule, "anchorMs", max(0, now_ms))

    next_ms =
      if now_ms < anchor, do: anchor, else: anchor + (div(now_ms - anchor, period) + 1) * period

    case DateTime.from_unix(next_ms, :millisecond) do
      {:ok, instant} -> {:ok, instant}
      {:error, _} -> :none
    end
  end

  defp stagger_offset(_job_id, window) when window <= 1, do: {:ok, 0}

  defp stagger_offset(job_id, window) when is_binary(job_id) do
    <<word::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, job_id)
    {:ok, rem(word, window)}
  end

  defp stagger_offset(_job_id, _window), do: {:error, :missing_schedule_identity}

  defp staggered_next(_expr, _timezone, _now_ms, _cursor_ms, _offset, 0), do: :none

  defp staggered_next(expr, timezone, now_ms, cursor_ms, offset, attempts) do
    with {:ok, cursor} <- DateTime.from_unix(cursor_ms, :millisecond),
         {:ok, base} <- CronSchedule.next_after(expr, timezone, cursor) do
      base_ms = DateTime.to_unix(base, :millisecond)

      case DateTime.from_unix(base_ms + offset, :millisecond) do
        {:ok, shifted} when base_ms + offset > now_ms ->
          {:ok, shifted}

        _ ->
          staggered_next(
            expr,
            timezone,
            now_ms,
            max(cursor_ms + 1, base_ms + 1_000),
            offset,
            attempts - 1
          )
      end
    end
  end
end
