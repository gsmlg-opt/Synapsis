defmodule Synapsis.Provider.WebSearch.Tavily do
  @moduledoc "Tavily search wire format and ordered portable results."

  alias Synapsis.Provider.WebSearch.TextBudget

  @string_keys ~w(search_depth topic time_range)
  @array_keys ~w(include_domains exclude_domains)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  def prepare(_config, arguments) do
    prepared = Map.drop(arguments, @string_keys ++ @array_keys)

    prepared =
      Enum.reduce(@string_keys, prepared, fn key, prepared ->
        optional(prepared, key, trim(arguments[key]))
      end)

    {:ok,
     Enum.reduce(@array_keys, prepared, fn key, prepared ->
       optional(prepared, key, strings(arguments[key]))
     end)}
  end

  def request(config, args) do
    body =
      %{"query" => args["query"], "max_results" => args["count"]}
      |> optional("search_depth", args["search_depth"])
      |> optional("topic", args["topic"])
      |> optional("include_answer", if(args["include_answer"] == true, do: true))
      |> optional("time_range", args["time_range"])
      |> optional("include_domains", args["include_domains"])
      |> optional("exclude_domains", args["exclude_domains"])

    uri = config.base_url |> String.trim() |> URI.parse()
    path = String.replace(uri.path || "", ~r/\/$/, "") <> "/search"
    url = URI.to_string(%{uri | path: path})

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"x-client-source", "openclaw"}
    ]

    headers =
      if is_binary(config[:api_key]) and config.api_key != "",
        do: [{"authorization", "Bearer " <> config.api_key} | headers],
        else: headers

    {:ok, :post, url, headers, body}
  end

  def result(_config, args, payload) do
    rows = list(payload["results"])

    results =
      rows
      |> Enum.take(args["count"])
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(fn row ->
        case result_url(row["url"]) do
          nil ->
            []

          url ->
            [
              %{"title" => text(row["title"]), "url" => url, "snippet" => text(row["content"])}
              |> optional("score", if(is_number(row["score"]), do: row["score"]))
              |> optional("published", published(row["published_date"]))
            ]
        end
      end)

    result =
      %{"results" => results, "count" => length(results)}
      |> optional("answer", text(payload["answer"]))

    {:ok, if(length(rows) > args["count"], do: Map.put(result, "truncated", true), else: result)}
  end

  defp published(value) when is_binary(value) and byte_size(value) <= 31 do
    if Regex.match?(~r/^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9:.+Z-]{0,20})?$/, value) do
      if match?({:ok, _}, Date.from_iso8601(String.slice(value, 0, 10))), do: value
    else
      published_rfc(value)
    end
  end

  defp published(_), do: nil

  defp published_rfc(value) do
    case Regex.run(
           ~r/^([A-Z][a-z]{2}), ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT\z/,
           value
         ) do
      [_, weekday, day, month, year, hour, minute, second] ->
        with month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
             {:ok, date} <- Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
             true <- Enum.at(@weekdays, Date.day_of_week(date) - 1) == weekday,
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second),
                 {0, 3}
               ),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          DateTime.to_iso8601(datetime)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # URI covers ordinary HTTP(S) host/default-port and percent-encoding behavior.
  # Full WHATWG and external-content sanitizer/framing equivalence remain outside
  # this portable result; the existing UTF-16 content budget is applied by WebSearch.
  defp result_url(value) when is_binary(value) do
    if TextBudget.units(value) <= 2_048 do
      uri = value |> String.trim() |> URI.parse()
      scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

      if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        normalized = %{
          uri
          | scheme: scheme,
            host: String.downcase(uri.host),
            path: uri.path || "/"
        }

        url = normalized |> URI.to_string() |> URI.encode(&(&1 > 32 and &1 < 127))
        if TextBudget.units(url) <= 2_048, do: if(url == value <> "/", do: value, else: url)
      end
    end
  end

  defp result_url(_), do: nil

  defp strings(value) when is_list(value),
    do: value |> Enum.map(&trim/1) |> Enum.reject(&is_nil/1)

  defp strings(value) when is_binary(value), do: strings([value])
  defp strings(_), do: []

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, value) when value in [nil, "", []], do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
end
