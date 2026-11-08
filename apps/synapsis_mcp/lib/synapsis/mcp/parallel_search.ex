defmodule Synapsis.MCP.ParallelSearch do
  @moduledoc """
  One uncached Parallel free search through the official MCP client.

  Connections are call-owned and never enter configured MCP discovery or the
  tool catalog. Backplane owns JSON-RPC, HTTP/SSE and transport sessions. Search
  sessions belong to Parallel's research arguments and remain separate.
  """

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Response
  alias Synapsis.Provider.WebSearch.ParallelFree

  def search(config, arguments) do
    started = now()
    deadline = started + config.timeout_ms
    session = arguments["session_id"] || Ecto.UUID.generate()
    unique = make_ref()
    client = name(unique, :client)

    with {:ok, endpoint} <- ParallelFree.endpoint(config[:base_url]),
         {:ok, timeout} <- remaining(deadline),
         {:ok, supervisor} <-
           Client.start_link(
             name: client,
             transport_name: name(unique, :transport),
             one_shot: true,
             protocol_version: "2025-06-18",
             client_info: %{"name" => "synapsis-parallel", "version" => "1"},
             capabilities: %{},
             timeout: timeout,
             transport:
               {:streamable_http,
                url: endpoint,
                headers: %{"user-agent" => "synapsis-parallel/1"},
                enable_sse: false}
           ) do
      result = observe(fn -> run(client, config, arguments, session, deadline) end)

      # A completed search is returned only after the official connection tree
      # acknowledges cleanup. Expired operations receive only the API's minimum
      # positive cleanup observation interval, never a renewed request budget.
      cleanup =
        observe(fn -> Client.close_connection(supervisor, timeout: max(deadline - now(), 1)) end)

      case {result, cleanup} do
        {{:ok, result}, {:ok, %{outcome: :confirmed}}} ->
          {:ok, Map.put(result, "tookMs", now() - started)}

        {{:error, _} = error, _} ->
          error

        _ ->
          {:error, :transport}
      end
    end
  end

  defp run(client, config, arguments, session, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         :ok <- Client.await_ready(client, timeout: timeout),
         {:ok, timeout} <- remaining(deadline),
         {:ok, handle} <-
           Client.start_tool_call(
             client,
             "web_search",
             ParallelFree.tool_arguments(arguments, session),
             timeout: timeout,
             registration_timeout: timeout
           ) do
      case Client.await_tool_call(handle, max(deadline - now(), 0)) do
        {:ok, %Response{is_error: false, result: raw_result}} ->
          ParallelFree.result(config, arguments, raw_result, session)

        error ->
          # Await does not cancel. Settle this tracked request through its public
          # owner API before the connection is retired; no extra request budget.
          case remaining(deadline) do
            {:ok, timeout} ->
              Client.cancel_tool_call(handle, "search_finished", notification_timeout: timeout)

            _ ->
              :ok
          end

          normalize_error(error)
      end
    else
      error -> normalize_error(error)
    end
  end

  defp name(unique, role),
    do: {:via, Registry, {Synapsis.MCP.Registry, {:parallel_free_search, unique, role}}}

  defp remaining(deadline) do
    case deadline - now() do
      timeout when timeout > 0 -> {:ok, timeout}
      _ -> {:error, :timeout}
    end
  end

  defp observe(fun) do
    fun.()
  rescue
    _ -> {:error, :transport}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :transport}
  end

  defp normalize_error({:error, :timeout} = error), do: error
  defp normalize_error(_), do: {:error, :transport}
  defp now, do: System.monotonic_time(:millisecond)
end
