defmodule Synapsis.Provider.Transport.Google do
  @moduledoc """
  Google Gemini default-endpoint helper.

  `Synapsis.Provider.Adapter` owns HTTP completion and streaming. Request,
  response, error, and SSE semantics live in `Backplane.AiProtocol.Codec`;
  this module does not implement a provider stream callback.
  """

  @default_base_url "https://generativelanguage.googleapis.com"

  @doc "Default base URL for Google Gemini API."
  def default_base_url, do: @default_base_url
end
