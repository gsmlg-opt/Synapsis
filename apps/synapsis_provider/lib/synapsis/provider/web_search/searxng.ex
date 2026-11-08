defmodule Synapsis.Provider.WebSearch.Searxng do
  @moduledoc "SearXNG search requests and ordered results before shared generic projection."

  alias Synapsis.Provider.WebSearch.Transport

  @doc "Normalize the explicitly configured base while retaining its path and query identity."
  def endpoint(base_url) do
    with value when is_binary(value) <- trim(base_url),
         value <- String.trim_trailing(value, "/"),
         %URI{scheme: scheme, host: host} <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      {:ok, value}
    else
      _ -> invalid("SearXNG requires an explicit HTTP or HTTPS base URL")
    end
  end

  def prepare_config(config) do
    with {:ok, base} <- endpoint(config[:base_url]) do
      {:ok,
       config
       |> Map.put(:base_url, base)
       |> Map.put(:categories, trim(config[:categories]))
       |> Map.put(:language, trim(config[:language]))}
    end
  end

  def prepare(config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query),
         {:ok, count} <- count(arguments["count"], config[:count]) do
      {:ok,
       %{"query" => query, "count" => count}
       |> optional("categories", trim(arguments["categories"]) || trim(config[:categories]))
       |> optional("language", trim(arguments["language"]) || trim(config[:language]))}
    else
      _ -> invalid("SearXNG search requires a query and a count from 1 to 10")
    end
  end

  def request(config, args) do
    with {:ok, base} <- endpoint(config[:base_url]) do
      uri = URI.parse(base)
      path = String.trim_trailing(uri.path || "", "/")
      path = if String.ends_with?(path, "/search"), do: path, else: path <> "/search"

      query =
        [{"q", args["query"]}, {"format", "json"}]
        |> optional_query("categories", args["categories"])
        |> optional_query("language", args["language"])

      url = %{uri | path: path, query: URI.encode_query(query)} |> URI.to_string()
      {:ok, :get, url, [{"accept", "application/json"}], nil}
    end
  end

  def fetch(config, args) do
    deadline = System.monotonic_time(:millisecond) + config.timeout_ms

    with {:ok, payload} <- fetch_before(config, args, deadline) do
      if retained_rows(payload, args["count"]) == [] and general_fallback?(args["categories"]),
        do: fetch_before(config, Map.put(args, "categories", "general"), deadline),
        else: {:ok, payload}
    end
  end

  def result(_config, args, payload) when is_map(payload) do
    results = retained_rows(payload, args["count"])
    {:ok, %{"results" => results, "count" => length(results)}}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp fetch_before(config, args, deadline) do
    with {:ok, method, url, headers, body} <- request(config, args) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0,
        do: Transport.json(method, url, headers, body, remaining, max_bytes: 1_000_000),
        else: {:error, :timeout}
    end
  end

  defp retained_rows(payload, count) do
    payload["results"]
    |> list()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(is_binary(&1["url"]) and is_binary(&1["title"])))
    |> Enum.take(count)
    |> Enum.map(fn row ->
      %{"title" => row["title"], "url" => row["url"], "snippet" => text(row["content"])}
      |> optional("siteName", site(row["url"]))
      |> optional("img_src", nonempty_text(row["img_src"]))
    end)
  end

  defp general_fallback?(categories) when is_binary(categories) do
    categories =
      categories
      |> String.split(",")
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    categories != [] and "general" not in categories
  end

  defp general_fallback?(_), do: false

  defp site(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp count(raw, configured) when raw in [nil, ""], do: {:ok, configured_count(configured)}

  defp count(raw, configured) when is_binary(raw) do
    if String.trim(raw) == "", do: count(nil, configured), else: count(number(raw), configured)
  end

  defp count(raw, _configured)
       when is_number(raw) and raw >= 1 and raw <= 10 and trunc(raw) == raw,
       do: {:ok, trunc(raw)}

  defp count(_raw, _configured), do: :error

  defp configured_count(value) when is_number(value),
    do: value |> floor() |> max(1) |> min(10)

  defp configured_count(_), do: 5

  defp number(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?(?:(?:[0-9]+\.?[0-9]*)|(?:\.[0-9]+))(?:e[+-]?[0-9]+)?\z/i, value) do
      normalized = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
      normalized = Regex.replace(~r/\.(?=e|\z)/i, normalized, ".0")

      case Float.parse(normalized) do
        {number, ""} -> number
        _ -> :invalid
      end
    else
      :invalid
    end
  end

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp nonempty_text(value) when is_binary(value) and value != "", do: value
  defp nonempty_text(_), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp optional_query(query, _key, value) when value in [nil, ""], do: query
  defp optional_query(query, key, value), do: query ++ [{key, value}]
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_searxng_options", message}}
end
