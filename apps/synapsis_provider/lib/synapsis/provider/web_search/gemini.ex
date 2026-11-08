defmodule Synapsis.Provider.WebSearch.Gemini do
  @moduledoc "Google Search grounding requests and raw ordered Gemini answers."

  @default_base "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-3.6-flash"
  @freshness %{
    "day" => "day",
    "pd" => "day",
    "week" => "week",
    "pw" => "week",
    "month" => "month",
    "pm" => "month",
    "year" => "year",
    "py" => "year"
  }
  @days %{"week" => 7, "month" => 30, "year" => 365}
  @owned_headers ~w(content-type x-goog-api-client x-goog-api-key)
  @unsafe_headers ~w(connection content-length expect host keep-alive proxy-connection te trailer transfer-encoding upgrade)

  def endpoint(base) do
    uri = URI.parse(trim(base) || @default_base)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      host = String.downcase(uri.host)
      path = String.trim_trailing(uri.path || "", "/")

      path =
        if uri.scheme == "https" and host == "generativelanguage.googleapis.com" and path == "",
          do: "/v1beta",
          else: path

      {:ok,
       URI.to_string(%{uri | host: host, path: path, query: nil, fragment: nil, userinfo: nil})}
    else
      invalid("Gemini base URL must be an HTTP or HTTPS URL")
    end
  end

  def prepare_config(config) do
    with {:ok, base} <- endpoint(config[:base_url]),
         {:ok, headers} <- headers(config[:headers]) do
      {:ok,
       config
       |> Map.put(:base_url, base)
       |> Map.put(:model, trim(config[:model]) || @default_model)
       |> Map.put(:headers, headers)}
    end
  end

  def prepare(_config, arguments) do
    query = trim(arguments["query"])
    raw_freshness = trim(arguments["freshness"])
    freshness = if raw_freshness, do: @freshness[String.downcase(raw_freshness)]

    with true <- not is_nil(query),
         true <- valid_count?(arguments["count"]),
         true <- is_nil(trim(arguments["country"])) and is_nil(trim(arguments["language"])),
         true <- is_nil(raw_freshness) or not is_nil(freshness),
         {:ok, after_date} <- date(trim(arguments["date_after"])),
         {:ok, before_date} <- date(trim(arguments["date_before"])),
         true <- is_nil(freshness) or (is_nil(after_date) and is_nil(before_date)),
         true <- is_nil(after_date) or is_nil(before_date) or after_date <= before_date do
      {:ok,
       %{"query" => query}
       |> optional("freshness", freshness)
       |> optional("date_after", after_date)
       |> optional("date_before", before_date)}
    else
      _ ->
        invalid(
          "Gemini requires a query, optional count from 1 to 10, and compatible freshness or date filters"
        )
    end
  end

  def request(config, args),
    do: request(config, args, config[:request_time] || DateTime.utc_now())

  def request(config, args, %DateTime{} = now) do
    with {:ok, config} <- prepare_config(config) do
      query =
        if args["freshness"] == "day",
          do:
            args["query"] <>
              "\n\nSearch recency instruction: Prioritize web sources published in the last 24 hours. If no matching recent sources are available, state that limitation and use the most relevant available sources.",
          else: args["query"]

      body = %{
        "contents" => [%{"parts" => [%{"text" => query}]}],
        "tools" => [%{"google_search" => time_filter(args, now)}]
      }

      # Operator headers cannot replace Google-owned fields. Attribution follows
      # the host's Google convention; no OpenClaw product header is fabricated.
      headers =
        config.headers
        |> Map.put("content-type", "application/json")
        |> Map.put("x-goog-api-key", config.api_key)

      {:ok, :post, config.base_url <> "/models/" <> config.model <> ":generateContent",
       Enum.sort(headers), body}
    end
  end

  def result(config, _args, payload) when is_map(payload) do
    with true <- not Map.has_key?(payload, "error"),
         true <- optional_field?(payload, "candidates", &is_list/1),
         true <- optional_field?(payload, "promptFeedback", &is_map/1),
         candidate = List.first(payload["candidates"] || []) || %{},
         true <- is_map(candidate),
         true <- optional_field?(candidate, "content", &is_map/1),
         true <- optional_field?(candidate["content"] || %{}, "parts", &is_list/1),
         parts = get_in(candidate, ["content", "parts"]) || [],
         true <- is_list(parts),
         content = parts |> Enum.flat_map(&part_text/1) |> Enum.join("\n"),
         true <- content != "",
         true <- optional_field?(candidate, "groundingMetadata", &is_map/1),
         true <-
           optional_field?(candidate["groundingMetadata"] || %{}, "groundingChunks", &is_list/1),
         chunks = get_in(candidate, ["groundingMetadata", "groundingChunks"]) || [],
         true <- is_list(chunks) do
      {:ok,
       %{
         "content" => content,
         "model" => trim(config[:model]) || @default_model,
         "citations" => Enum.flat_map(chunks, &citation/1)
       }}
    else
      _ -> {:error, :provider_response}
    end
  end

  def result(_, _, _), do: {:error, :provider_response}

  defp part_text(%{"text" => text}) when is_binary(text) and text != "", do: [text]
  defp part_text(_), do: []

  defp citation(%{"web" => %{"uri" => url} = web}) when is_binary(url) do
    row = %{"url" => url}
    [if(is_binary(web["title"]), do: Map.put(row, "title", web["title"]), else: row)]
  end

  defp citation(_), do: []

  defp time_filter(%{"freshness" => period}, now) when period in ["week", "month", "year"] do
    range(
      DateTime.add(now, -Map.fetch!(@days, period) * 86_400, :second) |> timestamp(),
      timestamp(now)
    )
  end

  defp time_filter(%{"freshness" => "day"}, _now), do: %{}

  defp time_filter(args, now) do
    if args["date_after"] || args["date_before"] do
      start =
        if args["date_after"],
          do: args["date_after"] <> "T00:00:00Z",
          else: "1970-01-01T00:00:00Z"

      finish =
        if args["date_before"],
          do:
            args["date_before"]
            |> Date.from_iso8601!()
            |> Date.add(1)
            |> Date.to_iso8601()
            |> Kernel.<>("T00:00:00Z"),
          else: timestamp(now)

      range(start, finish)
    else
      %{}
    end
  end

  defp range(start, finish),
    do: %{"timeRangeFilter" => %{"startTime" => start, "endTime" => finish}}

  defp timestamp(now),
    do:
      now
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp headers(nil), do: {:ok, %{}}

  defp headers(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, value}, {:ok, result} ->
      if is_binary(name) and is_binary(value) and
           Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name) do
        name = String.downcase(name)
        value = Regex.replace(~r/\A[ \t\r\n]+|[ \t\r\n]+\z/, value, "")

        cond do
          name in @unsafe_headers or String.contains?(value, ["\r", "\n", <<0>>]) or
              not Enum.all?(String.to_charlist(value), &(&1 <= 255)) ->
            {:halt, invalid("Gemini operator headers are invalid")}

          name in @owned_headers ->
            {:cont, {:ok, result}}

          true ->
            {:cont, {:ok, Map.put(result, name, value)}}
        end
      else
        {:halt, invalid("Gemini operator headers are invalid")}
      end
    end)
  end

  defp headers(_), do: invalid("Gemini operator headers must be a map")

  defp date(nil), do: {:ok, nil}

  defp date(value) do
    value =
      case Regex.run(~r/\A(\d{1,2})\/(\d{1,2})\/(\d{4})\z/, value) do
        [_, month, day, year] ->
          year <>
            "-" <> String.pad_leading(month, 2, "0") <> "-" <> String.pad_leading(day, 2, "0")

        _ ->
          value
      end

    with {:ok, date} <- Date.from_iso8601(value),
         true <- date.year >= 100,
         do: {:ok, Date.to_iso8601(date)},
         else: (_ -> :error)
  end

  defp valid_count?(value) when value in [nil, ""], do: true

  defp valid_count?(value) when is_number(value),
    do: value >= 1 and value <= 10 and trunc(value) == value

  defp valid_count?(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      true
    else
      if Regex.match?(~r/\A[+-]?(?:(?:[0-9]+\.?[0-9]*)|(?:\.[0-9]+))(?:e[+-]?[0-9]+)?\z/i, value) do
        value = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
        value = Regex.replace(~r/\.(?=e|\z)/i, value, ".0")

        case Float.parse(value) do
          {number, ""} -> valid_count?(number)
          _ -> false
        end
      else
        false
      end
    end
  end

  defp valid_count?(_), do: false
  defp optional_field?(map, key, valid?), do: not Map.has_key?(map, key) or valid?.(map[key])
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_gemini_options", message}}
end
