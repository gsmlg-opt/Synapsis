defmodule Synapsis.Provider.Transport.Google do
  @moduledoc """
  Req-based transport for the Google Gemini API.

  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  alias Synapsis.Provider.Transport.SSE

  @default_base_url "https://generativelanguage.googleapis.com"

  @doc """
  Stream a request to the Gemini API.

  Sends `{:chunk, json_map}` messages to `caller` for each SSE event.
  Sends `:stream_done` on completion or `{:stream_error, reason}` on failure.
  """
  def stream(request, config, caller) do
    base_url = config[:base_url] || @default_base_url
    model = request[:model] || "gemini-2.0-flash"

    url =
      "#{base_url}/v1beta/models/#{model}:streamGenerateContent?alt=sse&key=#{config.api_key}"

    body = Map.drop(request, [:model, :stream])

    try do
      Req.post!(url,
        headers: [{"content-type", "application/json"}],
        json: body,
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

  @doc "Default base URL for Google Gemini API."
  def default_base_url, do: @default_base_url
end
