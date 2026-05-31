defmodule Synapsis.Provider.Transport.Google do
  @moduledoc """
  Req-based transport for the Google Gemini API.

  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  @default_base_url "https://generativelanguage.googleapis.com"

  @doc "Default base URL for Google Gemini API."
  def default_base_url, do: @default_base_url

  @doc """
  Stream a request to the Google Gemini API.

  Sends raw SSE events to `caller` as `{:chunk, map}`, followed by
  `:stream_done` on success or `{:stream_error, reason}` on failure.
  """
  def stream(request, config, caller) do
    base_url = config[:base_url] || config["base_url"] || @default_base_url
    model = request[:model] || request["model"] || "gemini-2.5-flash"

    url =
      "#{String.trim_trailing(to_string(base_url), "/")}/v1beta/models/#{model}:streamGenerateContent?alt=sse"

    body = Map.drop(request, [:model, :stream, "model", "stream"])

    headers = [
      {"content-type", "application/json"},
      {"x-goog-api-key", config[:api_key] || config["api_key"]}
    ]

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: 300_000,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} =
              Synapsis.Provider.Transport.SSE.accumulate_and_parse(data, resp.body || "")

            for raw <- events, do: send(caller, {:chunk, raw})

            {:cont, {req, %{resp | body: buffer}}}
          end
        )

      if resp.status >= 400 do
        send(caller, {:stream_error, "Google stream failed"})
      else
        send(caller, :stream_done)
      end
    rescue
      e -> send(caller, {:stream_error, "Google stream failed"})
    end
  end
end
