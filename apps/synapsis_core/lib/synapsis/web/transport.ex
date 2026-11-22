defmodule Synapsis.Web.Transport do
  @moduledoc "Bounded native web transport using http_fetch and verified HTTPS."

  alias Backplane.AgentRuntime.Error

  # Keep fetched text inside the existing public projection's string budget.
  @max_body 262_144

  def request(%URI{} = uri, timeout, max_bytes)
      when is_integer(timeout) and timeout > 0 and is_integer(max_bytes) and max_bytes > 0 do
    # The task also bounds pool checkout plus connection and response together.
    # Its link ends the request if the native execution owner is cancelled.
    task = Task.async(fn -> perform(uri, timeout, min(max_bytes, @max_body), :get) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, Error.new(:timeout, "web request timed out")}
    end
  end

  @doc "Acquire unchanged document bytes under the separate readable-document bound."
  def document(%URI{} = uri, timeout)
      when is_integer(timeout) and timeout > 0 do
    task =
      Task.async(fn ->
        perform(uri, timeout, 750_000, :get, [
          {"accept", "text/markdown, text/html;q=0.9, */*;q=0.1"},
          {"user-agent",
           "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"},
          {"accept-language", "en-US,en;q=0.9"}
        ])
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, Error.new(:timeout, "web request timed out")}
    end
  end

  @doc "Return a raw HEAD response without credentials, body collection or automatic redirects."
  def head(%URI{} = uri, timeout) when is_integer(timeout) and timeout > 0 do
    task = Task.async(fn -> perform(uri, timeout, 0, :head) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, Error.new(:timeout, "web request timed out")}
    end
  end

  defp perform(uri, timeout, limit, method, headers \\ []) do
    promise =
      HTTP.fetch(URI.to_string(uri),
        method: method,
        headers: headers,
        redirect: :manual,
        retry: false,
        decode_body: false,
        stream_response: true,
        timeout: timeout,
        connect_timeout: timeout
      )

    try do
      case HTTP.Promise.await(promise) do
        %HTTP.Response{} = response ->
          with {:ok, body} <- collect(response.body, limit, timeout) do
            {:ok,
             %{
               status: response.status,
               headers: HTTP.Headers.to_list(response.headers),
               body: body
             }}
          end

        {:error, _} = error ->
          response(error)
      end
    after
      HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise), 1_000)
    end
  rescue
    _exception -> response({:error, :request_failed})
  catch
    :exit, _reason -> response({:error, :request_failed})
  end

  defp collect(body, limit, _timeout) when is_binary(body) do
    if byte_size(body) <= limit, do: {:ok, body}, else: body_limit()
  end

  defp collect(stream, limit, timeout) when is_pid(stream) do
    monitor = Process.monitor(stream)

    try do
      send(stream, {:read_chunk, self(), :ack})
      collect_chunks(stream, monitor, limit, timeout, [])
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect_chunks(stream, monitor, left, timeout, chunks) do
    receive do
      {:stream_chunk, ^stream, chunk, ack} ->
        if byte_size(chunk) <= left do
          send(stream, {:stream_chunk_ack, ack})
          collect_chunks(stream, monitor, left - byte_size(chunk), timeout, [chunk | chunks])
        else
          body_limit()
        end

      {:stream_end, ^stream} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:stream_error, ^stream, _reason} ->
        response({:error, :request_failed})

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        response({:error, :request_failed})
    after
      timeout -> {:error, Error.new(:timeout, "web request timed out")}
    end
  end

  defp body_limit, do: {:error, Error.new(:budget_exceeded, "web response exceeds byte limit")}

  defp response({:error, _}),
    do: {:error, Error.new(:transient_transport, "web request failed")}
end
