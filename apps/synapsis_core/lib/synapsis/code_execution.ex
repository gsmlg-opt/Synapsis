defmodule Synapsis.CodeExecution do
  @moduledoc "Remote xAI analysis through its provider adapter, without caching or local execution."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Provider.CodeExecution

  def execute(config, arguments, opts \\ []) do
    with {:ok, prepared} <- CodeExecution.prepare(config, arguments) do
      case CodeExecution.execute(config, prepared) do
        {:ok, result} ->
          if :erlang.external_size(result) <= Keyword.get(opts, :result_limit, 1_000_000) do
            {:ok, result}
          else
            failure(:budget_exceeded, "Code execution result exceeds its configured bound")
          end

        {:error, :timeout} ->
          failure(:timeout, "Code execution provider request timed out")

        {:error, :response_too_large} ->
          failure(:budget_exceeded, "Code execution provider response exceeds its byte bound")

        {:error, :transport} ->
          failure(:transient_transport, "Code execution provider request failed")

        {:error, {:http_status, _}} ->
          failure(
            :transient_transport,
            "Code execution provider returned an unsuccessful response"
          )

        {:error, _} ->
          failure(:malformed_result, "Code execution provider returned an unsupported response")
      end
    else
      {:error, {:invalid_arguments, code, message}} ->
        {:error, Error.new(:validation, message, details: %{reason: code})}
    end
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
