defmodule Synapsis.Provider.WebSearch.Kimi do
  @moduledoc "Kimi search requests and ordered results before shared generic projection."

  @unsupported ~w(country language freshness date_after date_before)

  def prepare(config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query),
         true <- Enum.all?(@unsupported, &is_nil(trim(arguments[&1]))),
         {:ok, count} <- count(arguments["count"], Map.get(config, :count)) do
      {:ok, %{"query" => query, "count" => count}}
    else
      _ -> invalid("Kimi search requires a query and a count from 1 to 10")
    end
  end

  @doc "Normalize the configured base while retaining its path prefix."
  def endpoint(base_url) do
    value = trim(base_url) || "https://api.moonshot.ai/v1"

    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if host != "",
          do: {:ok, String.trim_trailing(value, "/")},
          else: invalid("Kimi base URL must be an HTTP or HTTPS URL")

      _ ->
        invalid("Kimi base URL must be an HTTP or HTTPS URL")
    end
  end

  def request(config, args) do
    with {:ok, base_url} <- endpoint(config[:base_url]) do
      {:ok, :post, base_url <> "/tools/search",
       [
         {"accept", "application/json"},
         {"authorization", "Bearer " <> config.api_key},
         {"content-type", "application/json"}
       ], %{"text_query" => args["query"], "limit" => args["count"]}}
    end
  end

  def result(_config, args, %{"search_results" => rows}) when is_list(rows) do
    results = rows |> Enum.take(args["count"]) |> Enum.map(&row/1)
    {:ok, %{"results" => results, "count" => length(results)}}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp row(entry) when is_map(entry) and not is_struct(entry) do
    url = trim(entry["url"]) || ""
    host = URI.parse(url).host

    %{
      "title" => trim(entry["title"]) || "",
      "url" => url,
      "description" => trim(entry["snippet"]) || ""
    }
    |> optional("published", published(entry["date"]))
    |> optional("siteName", if(is_binary(host), do: String.downcase(host)))
  end

  defp row(_), do: row(%{})

  defp published(value) do
    case trim(value) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value), do: value

      _ ->
        nil
    end
  end

  defp count(raw, configured) when raw in [nil, ""], do: {:ok, configured_count(configured)}

  defp count(raw, configured) when is_binary(raw) do
    if String.trim(raw) == "" do
      count(nil, configured)
    else
      count(number(raw), configured)
    end
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
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_kimi_options", message}}
end
