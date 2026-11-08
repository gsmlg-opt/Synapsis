defmodule Synapsis.Provider.WebSearch.Parallel do
  @moduledoc "Shared Parallel search preparation, paid requests and portable ordered factory results."

  alias Synapsis.Provider.WebSearch.TextBudget

  def prepare(config, arguments) do
    objective = bounded(arguments["objective"], 5_000)
    query = bounded(arguments["query"], 5_000)
    queries = queries(arguments["search_queries"])
    queries = if queries == [] and is_binary(query), do: queries(query), else: queries

    with true <- queries != [],
         {:ok, count} <- count(arguments["count"], config[:count]) do
      session = trim(arguments["session_id"])
      session_limit = if config[:provider] == "parallel-free", do: 100, else: 1_000
      session = if is_binary(session) and TextBudget.units(session) <= session_limit, do: session

      {:ok,
       %{"search_queries" => queries, "count" => count}
       |> optional("objective", objective)
       |> optional("session_id", session)
       |> optional("client_model", bounded(arguments["client_model"], 100))}
    else
      _ -> invalid("Parallel search requires keyword search queries and a count from 1 to 40")
    end
  end

  @doc "Canonicalize Parallel's route while retaining the configured path prefix and query."
  def endpoint(base_url) do
    value = trim(base_url) || "https://api.parallel.ai/v1/search"

    value =
      if Regex.match?(~r/\A[a-z][a-z0-9+.-]*:\/\//i, value),
        do: Regex.replace(~r/\A[a-z][a-z0-9+.-]*(?=:\/\/)/i, value, &String.downcase/1),
        else: "https://" <> value

    with %URI{scheme: scheme, host: host} = uri <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      path = String.trim_trailing(uri.path || "", "/")
      path = if String.ends_with?(path, "/v1/search"), do: path, else: path <> "/v1/search"
      {:ok, URI.to_string(%{uri | host: String.downcase(host), path: path, fragment: nil})}
    else
      _ -> invalid("Parallel base URL must be an HTTP or HTTPS URL")
    end
  end

  def request(config, args) do
    with {:ok, endpoint} <- endpoint(config[:base_url]) do
      body =
        %{
          "search_queries" => args["search_queries"],
          "advanced_settings" => %{"max_results" => args["count"]}
        }
        |> optional("objective", args["objective"])
        |> optional("session_id", args["session_id"])
        |> optional("client_model", args["client_model"])

      {:ok, :post, endpoint,
       [
         {"accept", "application/json"},
         {"content-type", "application/json"},
         {"x-api-key", config.api_key},
         {"user-agent", "synapsis-parallel/1"}
       ], body}
    end
  end

  def result(_config, args, payload) when is_map(payload) do
    results =
      payload["results"]
      |> list()
      |> Enum.filter(&(is_map(&1) and not is_struct(&1)))
      |> Enum.take(args["count"])
      |> Enum.map(&row/1)

    result =
      %{
        "searchQueries" => args["search_queries"],
        "count" => length(results),
        "results" => results
      }
      |> optional("objective", args["objective"])

    result =
      Enum.reduce([{"search_id", "searchId"}, {"session_id", "sessionId"}], result, fn
        {source, target}, result ->
          if is_binary(payload[source]),
            do: Map.put(result, target, payload[source]),
            else: result
      end)

    {:ok,
     Enum.reduce(~w(warnings usage), result, fn key, result ->
       if is_list(payload[key]) and payload[key] != [],
         do: Map.put(result, key, payload[key]),
         else: result
     end)}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp row(entry) do
    url = text(entry["url"])
    excerpts = entry["excerpts"] |> list() |> Enum.filter(&is_binary/1)
    host = URI.parse(String.trim(url)).host

    %{
      "title" => text(entry["title"]),
      "url" => url,
      "description" => Enum.join(excerpts, "\n\n")
    }
    |> optional("siteName", if(is_binary(host), do: String.downcase(host)))
    |> optional("published", nonempty(entry["publish_date"]))
    |> optional("excerpts", if(excerpts != [], do: excerpts))
  end

  defp queries(value) when is_binary(value), do: queries([value])

  defp queries(value) do
    value
    |> list()
    |> Enum.map(&bounded(&1, 200))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp count(raw, configured) when raw in [nil, ""], do: {:ok, configured_count(configured)}

  defp count(raw, configured) when is_binary(raw) do
    if String.trim(raw) == "", do: count(nil, configured), else: count(number(raw), configured)
  end

  defp count(raw, _configured)
       when is_number(raw) and raw >= 1 and raw <= 40 and trunc(raw) == raw,
       do: {:ok, trunc(raw)}

  defp count(_raw, _configured), do: :error

  defp configured_count(value) when is_number(value),
    do: value |> floor() |> max(1) |> min(40)

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

  defp bounded(value, limit) do
    case trim(value) do
      nil -> nil
      value -> value |> TextBudget.take(limit) |> elem(0) |> nonempty()
    end
  end

  defp trim(value) when is_binary(value), do: value |> String.trim() |> nonempty()
  defp trim(_), do: nil
  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_parallel_options", message}}
end
