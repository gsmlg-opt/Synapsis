defmodule Synapsis.Provider.Transport.Google do
  @moduledoc """
  Req-based transport for the Google Gemini API.

  Sends raw decoded JSON chunks to the caller — event mapping is handled
  by `EventMapper`.
  """

  @default_base_url "https://generativelanguage.googleapis.com"

  @doc "Default base URL for Google Gemini API."
  def default_base_url, do: @default_base_url
end
