defmodule Synapsis.Web.Scrape do
  @moduledoc "Native Firecrawl page scraping without a local result cache."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Provider.WebScrape.Firecrawl

  def scrape(config, arguments, opts \\ []) do
    case Firecrawl.scrape(config, arguments) do
      {:ok, result} ->
        if :erlang.external_size(result) <= Keyword.get(opts, :result_limit, 1_000_000) do
          {:ok, result}
        else
          failure(:budget_exceeded, "Scrape result exceeds its configured bound")
        end

      {:error, {:invalid_arguments, code, message}} ->
        {:error, Error.new(:validation, message, details: %{reason: code})}

      {:error, :timeout} ->
        failure(:timeout, "Scrape provider request timed out")

      {:error, :response_too_large} ->
        failure(:budget_exceeded, "Scrape provider response exceeds its byte bound")

      {:error, :transport} ->
        failure(:transient_transport, "Scrape provider request failed")

      {:error, {:http_status, _}} ->
        failure(:transient_transport, "Scrape provider returned an unsuccessful response")

      {:error, _} ->
        failure(:malformed_result, "Scrape provider returned an unsupported response")
    end
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
