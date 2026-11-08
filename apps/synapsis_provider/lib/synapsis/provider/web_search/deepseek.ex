defmodule Synapsis.Provider.WebSearch.DeepSeek do
  @moduledoc "DeepSeek search requests and ordered results before shared generic projection."

  alias Synapsis.Provider.WebSearch.TextBudget

  @unsupported ~w(country language freshness date_after date_before search_lang ui_lang domain_filter max_tokens max_tokens_per_page)

  def prepare(config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query) and length(String.codepoints(query)) <= 128,
         true <- Enum.all?(@unsupported, &(not Map.has_key?(arguments, &1))),
         {:ok, count} <- count(arguments["count"], Map.get(config, :count)) do
      {:ok, %{"query" => query, "count" => count}}
    else
      _ ->
        invalid(
          "DeepSeek search requires a query of 1 to 128 Unicode characters and a count from 1 to 10; put search operators directly in query"
        )
    end
  end

  @doc "Use the configured HTTP origin with DeepSeek's fixed search route."
  def endpoint(base_url) do
    with value when is_binary(value) <- trim(base_url) || "https://api.deepseek.com",
         %URI{scheme: scheme, host: host, port: port} <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      {:ok,
       URI.to_string(%URI{
         scheme: scheme,
         host: String.downcase(host),
         port: port,
         path: "/v1/tools/search"
       })}
    else
      _ -> invalid("DeepSeek base URL must be an HTTP or HTTPS URL")
    end
  end

  def request(config, args) do
    with {:ok, url} <- endpoint(config[:base_url]) do
      {:ok, :post, url,
       [
         {"accept", "application/json"},
         {"authorization", "Bearer " <> config.api_key},
         {"content-type", "application/json"}
       ], %{"query" => args["query"], "count" => args["count"], "need_content" => false}}
    end
  end

  def result(_config, args, %{"results" => rows}) when is_list(rows) do
    {rows, omitted} =
      rows
      |> Enum.take(args["count"])
      |> Enum.reduce({[], false}, fn entry, {rows, omitted} ->
        case row(entry) do
          nil -> {rows, true}
          row -> {[row | rows], omitted}
        end
      end)

    result = %{"results" => Enum.reverse(rows), "count" => length(rows)}
    {:ok, if(omitted, do: Map.put(result, "truncated", true), else: result)}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp row(entry) when is_map(entry) and not is_struct(entry) do
    if url = canonical_url(entry["url"]) do
      %{"title" => trim(entry["title"]) || "", "url" => url}
      |> optional("snippet", trim(entry["summary"]) || trim(entry["snippet"]))
      |> optional("published", trim(entry["date"]))
      |> optional("siteName", trim(entry["site_name"]))
    end
  end

  defp row(_), do: nil

  defp canonical_url(value) do
    with value when is_binary(value) <- trim(value),
         true <- TextBudget.units(value) <= 2048,
         %URI{scheme: scheme, host: host} = uri <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      url =
        %{uri | host: String.downcase(host), path: uri.path || "/"}
        |> URI.to_string()
        |> URI.encode(&(&1 > 32 and &1 < 127))

      if TextBudget.units(url) <= 2048, do: url
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
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
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_deepseek_options", message}}
end
