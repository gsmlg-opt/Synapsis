defmodule Synapsis.Provider.Transport.OpenAI do
  @moduledoc """
  Req-based transport for OpenAI Chat Completions API and all compatible APIs.

  Supports: OpenAI, Ollama, OpenRouter, Groq, DeepSeek, vLLM, Azure, and any
  OpenAI-compatible endpoint via configurable `base_url`.

  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  require Logger

  @default_base_url "https://api.openai.com"

  @doc "Fetch available models from the provider."
  def fetch_models(config) do
    base_url = config[:base_url] || config["base_url"] || @default_base_url
    headers = auth_headers(config)

    url = models_url(base_url, config)

    case Req.get(url, headers: headers, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok,
         Enum.map(models, fn m ->
           %{
             id: m["id"],
             name: m["name"] || m["id"],
             context_window: m["context_length"] || m["context_window"] || 128_000
           }
         end)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Default base URL for OpenAI API."
  def default_base_url, do: @default_base_url

  @doc """
  Stream a request to an OpenAI-compatible Chat Completions API.

  Sends raw SSE events to `caller` as `{:chunk, map | "[DONE]"}`, followed
  by `:stream_done` on success or `{:stream_error, reason}` on failure.
  Supports Azure deployments via `config[:azure]`.
  """
  def stream(request, config, caller) do
    base_url = config[:base_url] || config["base_url"] || @default_base_url

    {url, headers, body} =
      if config[:azure] do
        model = request[:model] || request["model"] || "gpt-4.1"
        api_version = config[:api_version] || "2024-02-15-preview"

        url =
          "#{String.trim_trailing(to_string(base_url), "/")}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}"

        headers = [{"api-key", config[:api_key]}, {"content-type", "application/json"}]
        {url, headers, Map.drop(request, [:model, "model"])}
      else
        url = "#{String.trim_trailing(to_string(base_url), "/")}/v1/chat/completions"
        headers = [{"content-type", "application/json"}] ++ auth_headers(config)
        {url, headers, request}
      end

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
        send(caller, {:stream_error, "HTTP #{resp.status}"})
      else
        send(caller, :stream_done)
      end
    rescue
      e -> send(caller, {:stream_error, Exception.message(e)})
    end
  end

  defp models_url(base_url, config) do
    base_url = String.trim_trailing(to_string(base_url), "/")
    type = config[:type] || config["type"]

    # Use bare /models only when the base_url already includes /v1, or the provider
    # is openai_compat (which may serve /models directly). Never use discover_models
    # to alter the URL — that flag controls cache-bypass, not endpoint shape.
    if type == "openai_compat" or String.ends_with?(base_url, "/v1") do
      "#{base_url}/models"
    else
      "#{base_url}/v1/models"
    end
  end

  defp auth_headers(config) do
    api_key = config[:api_key] || config["api_key"]

    if api_key not in [nil, ""] do
      [{"authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end
end
