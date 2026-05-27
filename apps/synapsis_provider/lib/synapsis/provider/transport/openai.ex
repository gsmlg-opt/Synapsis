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
        {:error, "HTTP #{status} from #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Default base URL for OpenAI API."
  def default_base_url, do: @default_base_url

  defp models_url(base_url, config) do
    base_url = String.trim_trailing(to_string(base_url), "/")

    if compatible_discovery?(config) or String.ends_with?(base_url, "/v1") do
      "#{base_url}/models"
    else
      "#{base_url}/v1/models"
    end
  end

  defp compatible_discovery?(config) do
    config[:discover_models] || config["discover_models"] || config[:type] == "openai_compat" ||
      config["type"] == "openai_compat"
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
