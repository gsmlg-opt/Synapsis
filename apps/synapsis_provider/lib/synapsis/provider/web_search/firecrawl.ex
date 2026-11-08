defmodule Synapsis.Provider.WebSearch.Firecrawl do
  @moduledoc "Firecrawl v2 search formats and ordered, portable page results."

  @array_keys ~w(sources categories include_domains exclude_domains)
  @string_keys ~w(tbs location country)

  def prepare(_config, arguments) do
    prepared =
      arguments
      |> Map.drop(@array_keys ++ @string_keys)
      |> Map.put("scrape_results", arguments["scrape_results"] == true)

    prepared =
      Enum.reduce(@array_keys, prepared, fn key, prepared ->
        optional(prepared, key, strings(arguments[key]))
      end)

    {:ok,
     Enum.reduce(@string_keys, prepared, fn key, prepared ->
       optional(prepared, key, trim(arguments[key]))
     end)}
  end

  def request(config, args) do
    body =
      %{"query" => args["query"], "limit" => args["count"]}
      |> optional("sources", args["sources"])
      |> optional("categories", args["categories"])
      |> optional("includeDomains", args["include_domains"])
      |> optional("excludeDomains", args["exclude_domains"])
      |> optional("tbs", args["tbs"])
      |> optional("location", args["location"])
      |> optional("country", args["country"])

    body =
      if args["scrape_results"] == true,
        do: Map.put(body, "scrapeOptions", %{"formats" => ["markdown"]}),
        else: body

    uri = config.base_url |> String.trim() |> URI.parse()
    url = URI.to_string(%{uri | path: "/v2/search", query: nil, fragment: nil})
    headers = [{"accept", "application/json"}, {"content-type", "application/json"}]

    headers =
      if is_binary(config[:api_key]) and config.api_key != "",
        do: [{"authorization", "Bearer " <> config.api_key} | headers],
        else: headers

    {:ok, :post, url, headers, body}
  end

  def result(_config, args, payload) do
    if payload["success"] == false do
      {:error, :provider_response}
    else
      data = record(payload["data"])
      envelopes = [payload["data"], payload["results"], data["results"], data["data"]]
      source_candidates = Enum.map(~w(web news images), &data[&1])
      sources = Enum.flat_map(source_candidates, &list/1)

      rows =
        Enum.find(envelopes, &is_list/1) ||
          if sources != [],
            do: sources,
            else:
              Enum.find(source_candidates, &is_list/1) ||
                list(get_in(payload, ["web", "results"]))

      results =
        rows
        |> Enum.filter(&is_map/1)
        |> Enum.take(100)
        |> Enum.flat_map(&row(&1, args["scrape_results"] == true))
        |> Enum.take(args["count"])

      {:ok, %{"results" => results, "count" => length(results)}}
    end
  end

  defp row(entry, scrape?) do
    metadata = record(entry["metadata"])

    url =
      first_string([entry["url"], entry["sourceURL"], entry["sourceUrl"], metadata["sourceURL"]])

    case result_url(url) do
      nil ->
        []

      url ->
        result = %{
          "title" => first_string([entry["title"], metadata["title"]]) || "",
          "url" => url,
          "description" =>
            first_string([entry["description"], entry["snippet"], entry["summary"]]) || "",
          "siteName" => String.replace_prefix(URI.parse(url).host || "", "www.", "")
        }

        published =
          first_string([
            entry["publishedDate"],
            entry["published"],
            metadata["publishedTime"],
            metadata["publishedDate"]
          ])

        content =
          if scrape?, do: first_string([entry["markdown"], entry["content"], entry["text"]])

        [result |> optional("published", published(published)) |> optional("content", content)]
    end
  end

  defp published(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9:.+Z-]{0,20})?$/, value) and
         match?({:ok, _}, Date.from_iso8601(String.slice(value, 0, 10))),
       do: value
  end

  defp published(_), do: nil

  # URI supplies ordinary host/default-port and percent-encoding normalization.
  # Preserve the reference's bare-origin spelling; full WHATWG equivalence is
  # separate from this ordinary HTTP(S) serialization.
  defp result_url(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        normalized =
          URI.to_string(%{uri | host: String.downcase(host), path: uri.path || "/"})
          |> URI.encode(&(&1 > 32 and &1 < 127))

        if byte_size(normalized) <= 2_048 do
          if normalized == value <> "/", do: value, else: normalized
        end

      _ ->
        nil
    end
  end

  defp result_url(_), do: nil
  defp first_string(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))

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
  defp record(value) when is_map(value), do: value
  defp record(_), do: %{}
end
