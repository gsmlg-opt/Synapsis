defmodule Synapsis.Provider.Transport.OpenAI do
  @moduledoc """
  Req-based transport for OpenAI Chat Completions API and all compatible APIs.

  Supports: OpenAI, Ollama, OpenRouter, Groq, DeepSeek, vLLM, Azure, and any
  OpenAI-compatible endpoint via configurable `base_url`.

  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  require Logger
  alias Synapsis.Provider.Transport.SSE

  @default_base_url "https://api.openai.com"

  @doc """
  Stream a request to an OpenAI-compatible chat completions endpoint.

  For Azure, set `config.azure` to `true` and provide `config.api_version`.
  The model will be used as the deployment name.

  Sends `{:chunk, json_map}` messages to `caller` for each SSE event.
  Sends `:stream_done` on completion or `{:stream_error, reason}` on failure.
  """
  def stream(request, config, caller) do
    base_url = config[:base_url] || @default_base_url
    {url, headers} = build_url_and_headers(base_url, request, config)

    # Strip model from body for Azure (it's in the URL)
    body = if config[:azure], do: Map.drop(request, [:model]), else: request

    try do
      Req.post!(url,
        headers: headers,
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
        Logger.warning("openai_stream_error", error: Exception.message(e))
        send(caller, {:stream_error, Exception.message(e)})
    end
  end

  @doc "Fetch available models from the provider."
  def fetch_models(config) do
    base_url = config[:base_url] || @default_base_url
    headers = auth_headers(config)

    case Req.get("#{base_url}/v1/models", headers: headers) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok,
         Enum.map(models, fn m ->
           %{id: m["id"], name: m["id"], context_window: m["context_length"] || 128_000}
         end)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Default base URL for OpenAI API."
  def default_base_url, do: @default_base_url

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_url_and_headers(base_url, request, %{azure: true} = config) do
    model = request[:model] || "gpt-4o"
    api_version = config[:api_version] || "2024-02-15-preview"

    url =
      "#{base_url}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}"

    headers = [
      {"api-key", config.api_key},
      {"content-type", "application/json"}
    ]

    {url, headers}
  end

  defp build_url_and_headers(base_url, _request, config) do
    url = "#{base_url}/v1/chat/completions"
    headers = [{"content-type", "application/json"}] ++ auth_headers(config)
    {url, headers}
  end

  defp auth_headers(config) do
    if config[:api_key] do
      [{"authorization", "Bearer #{config.api_key}"}]
    else
      []
    end
  end
end
