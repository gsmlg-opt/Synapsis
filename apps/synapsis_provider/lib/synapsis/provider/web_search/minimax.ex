defmodule Synapsis.Provider.WebSearch.MiniMax do
  @moduledoc "MiniMax search requests and ordered results before shared generic projection."

  def prepare(config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query),
         {:ok, count} <- count(arguments["count"], Map.get(config, :count)) do
      {:ok, %{"query" => query, "count" => count}}
    else
      _ -> invalid("MiniMax search requires a query and a count from 1 to 10")
    end
  end

  @doc "Use the configured HTTP origin with MiniMax's fixed search route."
  def endpoint(base_url, region) do
    default = if region == "cn", do: "https://api.minimaxi.com", else: "https://api.minimax.io"

    with value when is_binary(value) <- trim(base_url) || default,
         %URI{scheme: scheme, host: host, port: port} <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      {:ok,
       URI.to_string(%URI{
         scheme: scheme,
         host: String.downcase(host),
         port: port,
         path: "/v1/coding_plan/search"
       })}
    else
      _ -> invalid("MiniMax base URL must be an HTTP or HTTPS URL")
    end
  end

  def request(config, args) do
    with {:ok, url} <- endpoint(config[:base_url], config[:region]) do
      {:ok, :post, url,
       [
         {"accept", "application/json"},
         {"authorization", "Bearer " <> config.api_key},
         {"content-type", "application/json"}
       ], %{"q" => args["query"]}}
    end
  end

  def result(_config, args, payload) when is_map(payload) do
    case get_in(payload, ["base_resp", "status_code"]) do
      status when status not in [nil, false] and status != 0 ->
        {:error, :provider_response}

      _ ->
        results = payload["organic"] |> list() |> Enum.take(args["count"]) |> Enum.map(&row/1)

        related =
          payload["related_searches"]
          |> list()
          |> Enum.map(& &1["query"])
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        result = %{"results" => results, "count" => length(results)}
        {:ok, if(related == [], do: result, else: Map.put(result, "relatedSearches", related))}
    end
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp row(entry) do
    url = nullish(entry["link"])

    %{
      "title" => nullish(entry["title"]),
      "url" => url,
      "description" => nullish(entry["snippet"])
    }
    |> optional("published", entry["date"])
    |> optional("siteName", site(url))
  end

  defp site(url) when is_binary(url) do
    case URI.parse(String.trim(url)).host do
      host when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp site(_), do: nil

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
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp nullish(nil), do: ""
  defp nullish(value), do: value
  defp optional(map, _key, value) when value in [nil, false, "", 0], do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_minimax_options", message}}
end
