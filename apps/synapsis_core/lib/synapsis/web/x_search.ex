defmodule Synapsis.Web.XSearch do
  @moduledoc "Native xAI X-search with its own bounded, caller-limited result cache."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Provider.XSearch
  alias Synapsis.Web.XSearch.Cache

  def search(config, arguments, opts \\ []) do
    with {:ok, prepared} <- XSearch.prepare(config, arguments) do
      ttl = Map.get(config, :cache_ttl_ms, 900_000)
      key = cache_key(config, prepared)

      case Cache.get(key, ttl) do
        {:ok, result} -> {:ok, Map.put(result, "cached", true)}
        :miss -> execute(config, prepared, key, ttl, opts)
      end
    else
      {:error, {:invalid_arguments, code, message}} ->
        {:error, Error.new(:validation, message, details: %{reason: code})}
    end
  end

  defp execute(config, prepared, key, ttl, opts) do
    case XSearch.search(config, prepared) do
      {:ok, result} ->
        if :erlang.external_size(result) <= Keyword.get(opts, :result_limit, 1_000_000) do
          :ok = Cache.put(key, result, ttl)
          {:ok, result}
        else
          failure(:budget_exceeded, "X search result exceeds its configured bound")
        end

      {:error, :timeout} ->
        failure(:timeout, "X search provider request timed out")

      {:error, :response_too_large} ->
        failure(:budget_exceeded, "X search provider response exceeds its byte bound")

      {:error, :transport} ->
        failure(:transient_transport, "X search provider request failed")

      {:error, {:http_status, _}} ->
        failure(:transient_transport, "X search provider returned an unsuccessful response")

      {:error, _} ->
        failure(:malformed_result, "X search provider returned an unsupported response")
    end
  end

  defp cache_key(config, prepared) do
    identity =
      {config[:credential_id], config[:credential_version],
       :crypto.hash(:sha256, config[:api_key] || "")}

    normalized = Map.drop(prepared, [:timeout_ms])
    :crypto.hash(:sha256, :erlang.term_to_binary({identity, normalized}, [:deterministic]))
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
