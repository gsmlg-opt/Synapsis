defmodule Synapsis.Provider.WebSearch.Perplexity do
  @moduledoc "Perplexity Search API request and result mapping."

  @search_keys ~w(country language date_after date_before domain_filter max_tokens max_tokens_per_page)
  @optional_keys ["freshness" | @search_keys]
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

  def prepare_config(%{mode: mode}) when mode != "search_api",
    do: {:error, :unsupported_perplexity_mode}

  def prepare_config(config), do: {:ok, Map.put(config, :mode, "search_api")}

  def prepare(_config, arguments) do
    values = Map.new(@optional_keys -- ["domain_filter"], &{&1, trim(arguments[&1])})
    freshness = if values["freshness"], do: @freshness[String.downcase(values["freshness"])]
    domains = domains(arguments["domain_filter"])

    with true <- not is_nil(trim(arguments["query"])),
         true <- is_nil(values["freshness"]) or not is_nil(freshness),
         true <- is_nil(values["language"]) or Regex.match?(~r/^[a-z]{2}$/i, values["language"]),
         true <-
           is_nil(freshness) or (is_nil(values["date_after"]) and is_nil(values["date_before"])),
         {:ok, after_date} <- date(values["date_after"]),
         {:ok, before_date} <- date(values["date_before"]),
         true <- is_nil(after_date) or is_nil(before_date) or after_date <= before_date,
         true <- length(domains) <= 20,
         true <-
           Enum.all?(domains, &String.starts_with?(&1, "-")) or
             Enum.all?(domains, &(not String.starts_with?(&1, "-"))),
         true <- positive?(arguments["max_tokens"], 1_000_000),
         true <- positive?(arguments["max_tokens_per_page"], 9_007_199_254_740_991) do
      prepared =
        arguments |> Map.drop(@optional_keys) |> Map.put("query", trim(arguments["query"]))

      {:ok,
       prepared
       |> optional("freshness", freshness)
       |> optional("country", values["country"])
       |> optional("language", values["language"])
       |> optional("date_after", after_date)
       |> optional("date_before", before_date)
       |> optional("domain_filter", domains)
       |> optional("max_tokens", arguments["max_tokens"])
       |> optional("max_tokens_per_page", arguments["max_tokens_per_page"])}
    else
      _ ->
        {:error,
         {:invalid_arguments, "invalid_perplexity_options",
          "Perplexity search arguments are invalid for the configured mode"}}
    end
  end

  def request(config, args) do
    body =
      %{"query" => args["query"], "max_results" => args["count"]}
      |> optional("country", args["country"])
      |> optional("search_domain_filter", args["domain_filter"])
      |> optional("search_recency_filter", args["freshness"])
      |> optional("search_language_filter", if(args["language"], do: [args["language"]]))
      |> optional("search_after_date_filter", request_date(args["date_after"]))
      |> optional("search_before_date_filter", request_date(args["date_before"]))
      |> optional("max_tokens", args["max_tokens"])
      |> optional("max_tokens_per_page", args["max_tokens_per_page"])

    uri = URI.parse(config.base_url)

    url =
      uri
      |> Map.put(:path, String.trim_trailing(uri.path || "", "/") <> "/search")
      |> Map.put(:query, nil)
      |> URI.to_string()

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> config.api_key}
    ]

    {:ok, :post, url, headers, body}
  end

  def result(_config, args, payload) do
    rows =
      payload
      |> Map.get("results", [])
      |> Enum.take(args["count"])
      |> Enum.map(fn row ->
        url = text(row["url"])

        %{"title" => text(row["title"]), "url" => url, "description" => text(row["snippet"])}
        |> optional("published", row["date"])
        |> optional("siteName", site(url))
      end)

    {:ok, %{"results" => rows, "count" => length(rows)}}
  end

  defp date(nil), do: {:ok, nil}

  defp date(value) do
    value =
      case Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/, value) do
        [_, month, day, year] ->
          year <>
            "-" <> String.pad_leading(month, 2, "0") <> "-" <> String.pad_leading(day, 2, "0")

        _ ->
          value
      end

    with {:ok, date} <- Date.from_iso8601(value),
         true <- date.year >= 100,
         do: {:ok, value},
         else: (_ -> :error)
  end

  defp request_date(nil), do: nil

  defp request_date(value) do
    {:ok, date} = Date.from_iso8601(value)
    "#{date.month}/#{date.day}/#{date.year}"
  end

  defp domains(value) when is_list(value),
    do: value |> Enum.map(&trim/1) |> Enum.reject(&is_nil/1)

  defp domains(value) when is_binary(value), do: domains([value])
  defp domains(_), do: []
  defp positive?(nil, _), do: true
  defp positive?(value, max), do: is_integer(value) and value > 0 and value <= max

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp site(url), do: String.replace_prefix(URI.parse(url).host || "", "www.", "")
  defp optional(map, _key, value) when value in [nil, "", []], do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
