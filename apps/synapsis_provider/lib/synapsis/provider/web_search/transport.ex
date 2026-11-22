defmodule Synapsis.Provider.WebSearch.Transport do
  @moduledoc false

  alias Synapsis.Provider.Transport.HTTP, as: Transport

  @max_body 16 * 1024 * 1024

  def json(method, url, headers, body, timeout, opts \\ []) do
    request(method, url, headers, body, timeout, opts, :json)
  end

  def text(method, url, headers, body, timeout, opts \\ []) do
    request(method, url, headers, body, timeout, opts, :text)
  end

  defp request(method, url, headers, body, timeout, opts, format) do
    options = [
      method: method,
      headers: headers,
      timeout: timeout,
      max_bytes: Keyword.get(opts, :max_bytes, @max_body)
    ]

    options =
      if is_nil(body), do: options, else: Keyword.put(options, :body, Formata.JSON.encode!(body))

    case Transport.request(url, options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> decode(body, format)
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, :response_too_large} = error -> error
      {:error, %HTTP.RequestError{reason: :timeout}} -> {:error, :timeout}
      {:error, _reason} -> {:error, :transport}
    end
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp decode(body, :text), do: {:ok, body}

  defp decode(body, :json) do
    case Formata.JSON.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end
end
