defmodule Synapsis.Provider.Transport.Anthropic do
  @moduledoc """
  Req-based transport for the Anthropic Messages API.

  Handles URL construction, authentication headers, and SSE streaming.
  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  @default_base_url "https://api.anthropic.com"

  @doc "Default base URL for Anthropic API."
  def default_base_url, do: @default_base_url
end
