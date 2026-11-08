defmodule Synapsis.RoutineSchedule do
  @moduledoc "Pure validation and normalization of stored routine schedules."

  @max_timestamp 8_640_000_000_000_000
  @number ~r/\A[+-]?(?:(?:\d+\.?\d*)|(?:\.\d+))(?:e[+-]?\d+)?\z/i

  def normalize(schedule, opts \\ [])

  def normalize(schedule, _opts) when is_binary(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, _} -> {:ok, schedule}
      _ -> {:error, :schedule}
    end
  end

  def normalize(schedule, opts) when is_map(schedule) do
    schedule = Map.new(schedule, fn {key, value} -> {to_string(key), value} end)

    case schedule["kind"] do
      "cron" -> normalize_cron(schedule)
      "at" -> normalize_at(schedule)
      "every" -> normalize_every(schedule, opts)
      _ -> {:error, :schedule}
    end
  end

  def normalize(_, _), do: {:error, :schedule}

  @doc false
  def fingerprint(schedule, timezone) do
    with {:ok, normalized} <- normalize(schedule) do
      bytes = :erlang.term_to_binary({normalized, timezone}, [:deterministic])
      {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end
  end

  def validate(schedule) do
    case normalize(schedule) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def parse_at(value) when is_binary(value) do
    raw = String.trim(value)

    if Regex.match?(~r/\A\d+\z/, raw) do
      with {ms, ""} when ms > 0 and ms <= @max_timestamp <- Integer.parse(raw),
           {:ok, datetime} <- DateTime.from_unix(ms, :millisecond) do
        {:ok, datetime}
      else
        _ -> {:error, :schedule}
      end
    else
      parse_iso(raw)
    end
  end

  def parse_at(_), do: {:error, :schedule}

  @doc "Coerce finite temporal numbers using the reference decimal grammar and Date range."
  def number(value)
      when is_number(value) and value >= -@max_timestamp and value <= @max_timestamp,
      do: {:ok, value}

  def number(value) when is_binary(value) do
    raw = String.trim(value)

    if Regex.match?(@number, raw) do
      case Float.parse(raw) do
        {number, ""} -> number(number)
        _ -> {:error, :schedule}
      end
    else
      {:error, :schedule}
    end
  end

  def number(_), do: {:error, :schedule}

  defp normalize_cron(%{"expr" => expr} = schedule) when is_binary(expr) do
    with {:ok, _} <- normalize(expr),
         true <- not Map.has_key?(schedule, "tz") or is_binary(schedule["tz"]),
         {:ok, stagger} <- cron_stagger(schedule) do
      normalized = %{"kind" => "cron", "expr" => String.trim(expr)}
      timezone = schedule["tz"]

      normalized =
        if is_binary(timezone) and String.trim(timezone) != "",
          do: Map.put(normalized, "tz", String.trim(timezone)),
          else: normalized

      if is_nil(stagger),
        do: {:ok, normalized},
        else: {:ok, Map.put(normalized, "staggerMs", stagger)}
    else
      _ -> {:error, :schedule}
    end
  end

  defp normalize_cron(_), do: {:error, :schedule}

  defp cron_stagger(schedule) do
    case Map.fetch(schedule, "staggerMs") do
      :error -> {:ok, nil}
      {:ok, value} -> normalize_stagger(value)
    end
  end

  defp normalize_stagger(value) when is_number(value) and value <= @max_timestamp,
    do: {:ok, max(0, floor(value))}

  defp normalize_stagger(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?\d+\z/, value) do
      case Integer.parse(value) do
        {number, ""} when number >= 0 and number <= @max_timestamp -> {:ok, number}
        _ -> {:error, :schedule}
      end
    else
      {:error, :schedule}
    end
  end

  defp normalize_stagger(_), do: {:error, :schedule}

  defp normalize_at(schedule) do
    with {:ok, datetime} <- parse_at(schedule["at"]),
         do: {:ok, %{"kind" => "at", "at" => DateTime.to_iso8601(datetime)}}
  end

  defp normalize_every(schedule, opts) do
    with {:ok, period} <- number(schedule["everyMs"]),
         period = floor(period),
         true <- period >= 1,
         {:ok, anchor} <- every_anchor(schedule, opts) do
      normalized = %{"kind" => "every", "everyMs" => period}

      if is_nil(anchor),
        do: {:ok, normalized},
        else: {:ok, Map.put(normalized, "anchorMs", anchor)}
    else
      _ -> {:error, :schedule}
    end
  end

  defp every_anchor(schedule, opts) do
    case Map.fetch(schedule, "anchorMs") do
      {:ok, value} ->
        with {:ok, number} <- number(value),
             true <- number >= 0,
             do: {:ok, floor(number)},
             else: (_ -> {:error, :schedule})

      :error ->
        case Keyword.fetch(opts, :anchor_ms) do
          {:ok, anchor} -> every_anchor(%{"anchorMs" => anchor}, [])
          :error -> {:ok, nil}
        end
    end
  end

  defp parse_iso(raw) do
    case Regex.run(
           ~r/\A(\d{4}-\d{2}-\d{2})(?:[Tt](\d{2}:\d{2})(?::(\d{2})(\.\d+)?)?([Zz]|[+-]\d{2}:?\d{2})?)?\z/,
           raw,
           capture: :all_but_first
         ) do
      nil -> {:error, :schedule}
      parts -> parse_iso_parts(parts ++ List.duplicate("", 5 - length(parts)))
    end
  end

  defp parse_iso_parts([date, time, second, fraction, offset]) do
    time = if time == "", do: "00:00", else: time
    second = if second == "", do: "00", else: second
    offset = if offset == "", do: "Z", else: String.upcase(offset)
    offset = Regex.replace(~r/([+-]\d{2})(\d{2})\z/, offset, "\\1:\\2")
    end_of_day? = time == "24:00" and second == "00" and not Regex.match?(~r/[1-9]/, fraction)
    time = if end_of_day?, do: "00:00", else: time
    fraction = if fraction == "", do: "", else: String.slice(fraction, 0, 4)

    case DateTime.from_iso8601(date <> "T" <> time <> ":" <> second <> fraction <> offset) do
      {:ok, datetime, _} ->
        if end_of_day?, do: {:ok, DateTime.add(datetime, 86_400, :second)}, else: {:ok, datetime}

      _ ->
        {:error, :schedule}
    end
  end
end
