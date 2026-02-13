defmodule Synapsis.Provider.Transport.Anthropic do
  @moduledoc """
  Req-based transport for the Anthropic Messages API.

  Handles URL construction, authentication headers, and SSE streaming.
  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  alias Synapsis.Provider.Transport.SSE

  @api_version "2023-06-01"
  @default_base_url "https://api.anthropic.com"

  @doc """
  Stream a request to the Anthropic Messages API.

  Sends `{:chunk, json_map}` messages to `caller` for each SSE event.
  Sends `:stream_done` on completion or `{:stream_error, reason}` on failure.
  """
  def stream(request, config, caller) do
    base_url = config[:base_url] || @default_base_url
    url = "#{base_url}/v1/messages"

    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    try do
      Req.post!(url,
        headers: headers,
        json: request,
        receive_timeout: 300_000,
        into: fn {:data, data}, acc ->
          for chunk <- SSE.parse_lines(data) do
            send(caller, {:chunk, chunk})
          end

          {:cont, acc}
        end
      )

      send(caller, :stream_done)
    rescue
      e ->
        send(caller, {:stream_error, Exception.message(e)})
    end
  end

  @doc "Default base URL for Anthropic API."
  def default_base_url, do: @default_base_url
end
