defmodule Synapsis.Provider.Transport.Anthropic do
  @moduledoc """
  Anthropic model-discovery and default-endpoint helper.

  `Synapsis.Provider.Adapter` owns HTTP completion and streaming. Request,
  response, error, and SSE semantics live in `Backplane.AiProtocol.Codec`;
  this module does not implement a provider stream callback.
  """

  @default_base_url "https://api.anthropic.com"

  @doc "Fetch available models from Anthropic or Anthropic-compatible APIs."
  def fetch_models(config) do
    base_url = config[:base_url] || config["base_url"] || @default_base_url

    url = models_url(base_url)

    case Req.get(url, headers: auth_headers(config), receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        {:ok, Enum.map(models, &model_from_response/1)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} from #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Default base URL for Anthropic API."
  def default_base_url, do: @default_base_url

  defp models_url(base_url) do
    base_url = String.trim_trailing(to_string(base_url), "/")

    if String.ends_with?(base_url, "/v1") do
      "#{base_url}/models"
    else
      "#{base_url}/v1/models"
    end
  end

  defp auth_headers(config) do
    api_key = config[:api_key] || config["api_key"]

    if api_key not in [nil, ""] do
      [
        {"x-api-key", api_key},
        {"authorization", "Bearer #{api_key}"},
        {"anthropic-version", "2023-06-01"}
      ]
    else
      [{"anthropic-version", "2023-06-01"}]
    end
  end

  defp model_from_response(%{"id" => id} = model) do
    %{
      id: id,
      name: model["display_name"] || model["name"] || id,
      context_window: model["context_length"] || model["context_window"] || 200_000
    }
  end
end
