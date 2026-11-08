defmodule Synapsis.Provider.WebSearch.Transport do
  @moduledoc false

  @max_body 16 * 1024 * 1024

  def json(method, url, headers, body, timeout, opts \\ []) do
    request(method, url, headers, body, timeout, opts, :json)
  end

  def text(method, url, headers, body, timeout, opts \\ []) do
    request(method, url, headers, body, timeout, opts, :text)
  end

  defp request(method, url, headers, body, timeout, opts, format) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_body)
    task = Task.async(fn -> perform(method, url, headers, body, timeout, max_bytes, format) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  defp perform(method, url, headers, body, timeout, max_bytes, format) do
    options = [
      method: method,
      url: url,
      headers: headers,
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      receive_timeout: timeout,
      request_timeout: timeout,
      finch: [pool_timeout: timeout, conn_opts: [transport_opts: [timeout: timeout]]],
      into: &collect(&1, &2, max_bytes)
    ]

    options = if is_nil(body), do: options, else: Keyword.put(options, :body, Jason.encode!(body))

    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(options)
    |> Req.request()
    |> response(format)
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, max_bytes) do
    {size, chunks} = Req.Response.get_private(response, :search_body, {0, []})

    if size + byte_size(data) <= max_bytes do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :search_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :search_limit, true)}}
    end
  end

  defp response({:ok, response}, format) do
    cond do
      Req.Response.get_private(response, :search_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :search_body, {0, []})

        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> decode(format)
    end
  end

  defp response({:error, _}, _format), do: {:error, :transport}

  defp decode(body, :text), do: {:ok, body}

  defp decode(body, :json) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end
end
