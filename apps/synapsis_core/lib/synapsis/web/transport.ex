defmodule Synapsis.Web.Transport do
  @moduledoc "Bounded native web transport using clean Req defaults and verified HTTPS."

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
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: method,
      headers: headers,
      url: URI.to_string(uri),
      raw: true,
      compressed: false,
      into: fn event, pair ->
        if method == :head, do: {:cont, pair}, else: collect(event, pair, limit)
      end,
      retry: false,
      redirect: false,
      receive_timeout: timeout,
      request_timeout: timeout,
      finch: [pool_timeout: timeout, conn_opts: [transport_opts: [timeout: timeout]]]
    )
    |> run_request()
    |> response()
  end

  # Finch can raise or exit on ordinary request failures (including pool
  # checkout timeout). Contain that boundary inside the linked task so it
  # returns an explicit failure instead of taking down the execution owner.
  defp run_request(request) do
    Req.request(request)
  rescue
    _exception -> {:error, :request_failed}
  catch
    :exit, _reason -> {:error, :request_failed}
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :web_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(response, :web_body, {size + byte_size(data), [data | chunks]})}}
    else
      {:halt, {request, Req.Response.put_private(response, :web_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    if Req.Response.get_private(response, :web_limit, false) do
      {:error, Error.new(:budget_exceeded, "web response exceeds byte limit")}
    else
      {_, chunks} = Req.Response.get_private(response, :web_body, {0, []})
      headers = for {key, values} <- response.headers, value <- values, do: {key, value}

      {:ok,
       %{
         status: response.status,
         headers: headers,
         body: IO.iodata_to_binary(Enum.reverse(chunks))
       }}
    end
  end

  defp response({:error, _}),
    do: {:error, Error.new(:transient_transport, "web request failed")}
end
