defmodule Synapsis.Provider.Transcription do
  @moduledoc """
  Transcription through an explicitly saved OpenAI-compatible speech provider.

  Only an available persisted `openai_speech` record may supply the connection.
  The saved API root receives the same `/v1` prefix normalization as TTS. The
  request and adapter result remain unchanged, including the adapter's model
  default. No provider discovery, retry, registry fallback, message mutation or
  inbound preprocessing is performed here.

  Call from a supervised execution task. The request's required `timeout_ms`
  bounds the adapter's HTTP work; it does not bound provider configuration reads.
  """

  alias Synapsis.Provider.Transcription.OpenAI
  alias Synapsis.Providers

  @spec transcribe(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transcribe(provider_name, request) when is_binary(provider_name) do
    with {:ok, %{type: "openai_speech"} = provider} <- Providers.get_by_name(provider_name),
         true <- Providers.runtime_available?(provider),
         {:ok, runtime} <- Providers.runtime_config(provider_name),
         true <- runtime[:provider_id] === provider.id and runtime[:type] == "openai_speech",
         base_url when is_binary(base_url) and base_url != "" <- runtime[:base_url] do
      root = String.trim_trailing(base_url, "/")
      prefix = if String.ends_with?(root, "/v1"), do: root, else: root <> "/v1"

      OpenAI.transcribe(request, %{api_key: runtime[:api_key], base_url: prefix})
    else
      _ -> {:error, :provider_unavailable}
    end
  end

  def transcribe(_provider_name, _request), do: {:error, :provider_unavailable}
end
