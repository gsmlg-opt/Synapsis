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

  defp auth_headers(config) do
    if config[:api_key] do
      [{"authorization", "Bearer #{config.api_key}"}]
    else
      []
    end
  end
end
