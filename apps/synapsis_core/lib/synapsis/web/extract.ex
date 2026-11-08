defmodule Synapsis.Web.Extract do
  @moduledoc "Native Tavily extraction with an independent fixed-lifetime result cache."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Provider.WebExtract.Tavily
  alias Synapsis.Web.Extract.Cache

  def extract(config, arguments, opts \\ []) do
    with {:ok, arguments} <- Tavily.prepare(config, arguments) do
      key = cache_key(config, arguments)

      case Cache.get(key) do
        {:ok, result} -> {:ok, Map.put(result, "cached", true)}
        :miss -> execute(config, arguments, key, opts)
      end
    else
      {:error, {:invalid_arguments, code, message}} ->
        {:error, Error.new(:validation, message, details: %{reason: code})}
    end
  end

  defp execute(config, arguments, key, opts) do
    case Tavily.extract(config, arguments) do
      {:ok, result} ->
        if :erlang.external_size(result) <= Keyword.get(opts, :result_limit, 1_000_000) do
          :ok = Cache.put(key, result)
          {:ok, result}
        else
          failure(:budget_exceeded, "Extraction result exceeds its configured bound")
        end

      {:error, :timeout} ->
        failure(:timeout, "Extraction provider request timed out")

      {:error, :response_too_large} ->
        failure(:budget_exceeded, "Extraction provider response exceeds its byte bound")

      {:error, :transport} ->
        failure(:transient_transport, "Extraction provider request failed")

      {:error, {:http_status, _}} ->
        failure(:transient_transport, "Extraction provider returned an unsuccessful response")

      {:error, _} ->
        failure(:malformed_result, "Extraction provider returned an unsupported response")
    end
  end

  defp cache_key(config, arguments) do
    identity =
      {config[:credential_id], config[:credential_version],
       :crypto.hash(:sha256, config[:api_key] || ""), config.base_url}

    :crypto.hash(:sha256, :erlang.term_to_binary({identity, arguments}, [:deterministic]))
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
