defmodule Synapsis.Provider.WebSearch.ParallelFree do
  @moduledoc """
  Pure Parallel free Search MCP arguments and portable factory results.

  The host permits an explicit complete endpoint override for a trusted proxy.
  The MCP adapter owns transport, protocol negotiation and connection lifetime.
  """

  alias Synapsis.Provider.WebSearch.Parallel

  def endpoint(nil), do: {:ok, "https://search.parallel.ai/mcp"}

  def endpoint(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, value}

      _ ->
        {:error,
         {:invalid_arguments, "invalid_endpoint",
          "Parallel free endpoint must be an HTTP or HTTPS URL"}}
    end
  end

  def endpoint(_),
    do:
      {:error,
       {:invalid_arguments, "invalid_endpoint",
        "Parallel free endpoint must be an HTTP or HTTPS URL"}}

  def tool_arguments(arguments, search_session_id) do
    %{
      "objective" => arguments["objective"] || Enum.join(arguments["search_queries"], " "),
      "search_queries" => arguments["search_queries"],
      "session_id" => search_session_id
    }
    |> optional("model_name", arguments["client_model"])
  end

  def result(config, arguments, raw_result, search_session_id) do
    with {:ok, payload} <- payload(raw_result),
         rows = if(is_list(payload["results"]), do: payload["results"], else: []),
         # The free MCP applies count before the shared record filtering.
         payload =
           payload
           |> Map.put("results", Enum.take(rows, arguments["count"]))
           |> Map.put("session_id", search_session_id),
         {:ok, result} <- Parallel.result(config, arguments, payload) do
      {:ok, Map.put(result, "provider", "parallel-free")}
    end
  end

  defp payload(%{"isError" => true}), do: {:error, :provider_response}

  defp payload(%{"structuredContent" => payload}) when is_map(payload), do: {:ok, payload}

  defp payload(%{"content" => content}) when is_list(content) do
    Enum.reduce_while(content, {:error, :provider_response}, fn
      %{"type" => "text", "text" => text}, result when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, payload} when is_map(payload) -> {:halt, {:ok, payload}}
          _ -> {:cont, result}
        end

      _, result ->
        {:cont, result}
    end)
  end

  defp payload(_), do: {:error, :provider_response}

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
