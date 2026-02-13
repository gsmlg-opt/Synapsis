defmodule Synapsis.Provider.Behaviour do
  @moduledoc """
  Behaviour for LLM provider integrations.
  Every provider must implement these callbacks.
  """

  @type config :: map()

  @type request :: map()
  @type stream_ref :: reference()

  @doc "Start a streaming request. Sends {:provider_chunk, chunk} and :provider_done to caller."
  @callback stream(request :: request(), config :: config()) ::
              {:ok, stream_ref()} | {:error, term()}

  @doc "Cancel an in-progress stream."
  @callback cancel(stream_ref()) :: :ok | {:error, term()}

  @doc "List available models for this provider."
  @callback models(config()) :: {:ok, [map()]} | {:error, term()}

  @doc "Format messages and tools into provider-specific request format."
  @callback format_request(messages :: [map()], tools :: [map()], opts :: map()) :: request()
end
