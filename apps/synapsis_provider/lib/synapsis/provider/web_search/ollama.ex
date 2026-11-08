defmodule Synapsis.Provider.WebSearch.Ollama do
  @moduledoc "Ollama search requests and ordered results before shared generic projection."

  alias Synapsis.Provider.WebSearch.{TextBudget, Transport}

  @default_base "http://127.0.0.1:11434"

  @doc "Remove trailing slashes and exactly one trailing /v1 from the selected base."
  def endpoint(base_url) do
    value = trim(base_url) || @default_base
    value = value |> String.trim_trailing("/") |> String.replace(~r/\/v1\z/i, "")
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
      do: {:ok, value},
      else: invalid("Ollama base URL must be an HTTP or HTTPS URL")
  end

  # A canonical prefix may itself end in /v1. Carry preparation identity only
  # in runtime configuration so later layers do not strip that prefix again.
  def prepare_config(%{base_url: base, ollama_prepared_base_url: prepared} = config)
      when is_binary(base) and base == prepared,
      do: {:ok, config}

  def prepare_config(config) do
    with {:ok, base} <- endpoint(config[:base_url]) do
      {:ok, config |> Map.put(:base_url, base) |> Map.put(:ollama_prepared_base_url, base)}
    end
  end

  def prepare(_config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query),
         {:ok, count} <- count(arguments["count"]) do
      {:ok, %{"query" => query, "count" => count}}
    else
      _ -> invalid("Ollama search requires a query and a count from 1 to 10")
    end
  end

  def hosted?(base_url) do
    uri = URI.parse(base_url)
    uri.scheme == "https" and is_binary(uri.host) and String.downcase(uri.host) == "ollama.com"
  end

  def request(config, args) do
    with {:ok, config} <- prepare_config(config) do
      path =
        if hosted?(config.base_url), do: "/api/web_search", else: "/api/experimental/web_search"

      headers = [{"content-type", "application/json"}]

      headers =
        case config[:api_key] do
          key when is_binary(key) and key != "" ->
            headers ++ [{"authorization", "Bearer " <> key}]

          _ ->
            headers
        end

      {:ok, :post, config.base_url <> path, headers,
       %{"query" => args["query"], "max_results" => args["count"]}}
    end
  end

  def fetch(config, args) do
    deadline = System.monotonic_time(:millisecond) + config.timeout_ms

    with {:ok, config} <- prepare_config(config),
         {:ok, method, url, headers, body} <- request(config, args) do
      case fetch_before(method, url, headers, body, deadline) do
        {:error, {:http_status, 404}} = error ->
          if hosted?(config.base_url),
            do: error,
            else:
              fetch_before(method, config.base_url <> "/api/web_search", headers, body, deadline)

        result ->
          result
      end
    end
  end

  def result(_config, args, payload) when is_map(payload) do
    results =
      payload["results"]
      |> list()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&row/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(args["count"])

    {:ok, %{"results" => results, "count" => length(results)}}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp fetch_before(method, url, headers, body, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: Transport.json(method, url, headers, body, remaining),
      else: {:error, :timeout}
  end

  defp row(entry) do
    case trim(entry["url"]) do
      nil ->
        nil

      url ->
        {snippet, _used} = TextBudget.take(trim(entry["content"]) || "", 300)

        %{"title" => trim(entry["title"]) || "", "url" => url, "snippet" => snippet}
        |> optional("siteName", site(url))
    end
  end

  defp site(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp count(raw) when raw in [nil, ""], do: {:ok, 5}

  defp count(raw) when is_binary(raw) do
    if String.trim(raw) == "", do: count(nil), else: count(number(raw))
  end

  defp count(raw) when is_number(raw) and raw >= 1 and raw <= 10 and trunc(raw) == raw,
    do: {:ok, trunc(raw)}

  defp count(_), do: :error

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
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_ollama_options", message}}
end
