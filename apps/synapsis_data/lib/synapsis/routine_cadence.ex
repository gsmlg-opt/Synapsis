defmodule Synapsis.RoutineCadence do
  @moduledoc "Presence-aware cadence normalization for version-one automations."

  alias Synapsis.RoutineSchedule

  @hour_list_part ~r/\A(?:(?:\d+|\d+-\d+)(?:\/\d+)?|[*?](?:\/\d+)?)\z/

  @doc "Normalize against the latest stored schedule without changing legacy defaults."
  def normalize(schedule, previous, opts) do
    schedule = stringify_keys(schedule)
    previous = stringify_keys(previous)

    with {:ok, normalized} <-
           schedule |> inherit_timezone(previous) |> RoutineSchedule.normalize() do
      normalize_cadence(normalized, previous, opts)
    end
  end

  @doc "Default five-minute window for recurring cron expressions at the top of an hour."
  def default_stagger_ms(expr) when is_binary(expr) do
    case String.split(expr, ~r/\s+/, trim: true) do
      ["0", hour, _day, _month, _weekday] -> recurring_hour_stagger(hour)
      ["0", "0", hour, _day, _month, _weekday] -> recurring_hour_stagger(hour)
      _ -> nil
    end
  end

  defp normalize_cadence(%{"kind" => "every"} = schedule, previous, opts) do
    anchor =
      cond do
        Map.has_key?(schedule, "anchorMs") ->
          schedule["anchorMs"]

        is_nil(previous) ->
          Keyword.fetch!(opts, :anchor_ms)

        same_interval?(schedule, previous) ->
          previous["anchorMs"] || Keyword.fetch!(opts, :anchor_ms)

        true ->
          Keyword.fetch!(opts, :now_ms)
      end

    RoutineSchedule.normalize(schedule, anchor_ms: anchor)
  end

  defp normalize_cadence(%{"kind" => "cron"} = schedule, previous, _opts) do
    stagger =
      cond do
        Map.has_key?(schedule, "staggerMs") -> schedule["staggerMs"]
        same_cron?(schedule, previous) -> previous["staggerMs"]
        true -> default_stagger_ms(schedule["expr"])
      end

    if is_nil(stagger),
      do: {:ok, schedule},
      else: {:ok, Map.put(schedule, "staggerMs", stagger)}
  end

  defp normalize_cadence(schedule, _previous, _opts), do: {:ok, schedule}

  defp inherit_timezone(%{"kind" => "cron"} = schedule, previous) do
    case Map.fetch(schedule, "tz") do
      {:ok, nil} -> Map.delete(schedule, "tz")
      :error when is_map(previous) -> inherit_cron_timezone(schedule, previous)
      _ -> schedule
    end
  end

  defp inherit_timezone(schedule, _previous), do: schedule

  defp inherit_cron_timezone(schedule, %{"kind" => "cron", "tz" => timezone}),
    do: Map.put(schedule, "tz", timezone)

  defp inherit_cron_timezone(schedule, _previous), do: schedule

  defp same_interval?(%{"everyMs" => period}, %{"kind" => "every", "everyMs" => period}),
    do: true

  defp same_interval?(_schedule, _previous), do: false

  defp same_cron?(%{"expr" => expr}, %{"kind" => "cron", "expr" => expr}), do: true
  defp same_cron?(_schedule, _previous), do: false

  defp recurring_hour_stagger(hour) do
    parts = String.split(hour, ",")

    if Enum.all?(parts, &Regex.match?(@hour_list_part, &1)) and
         Enum.any?(parts, &(String.starts_with?(&1, "*") or String.starts_with?(&1, "?"))),
       do: 300_000,
       else: nil
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(value), do: value
end
