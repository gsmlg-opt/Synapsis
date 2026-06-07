defmodule Synapsis.Provider.ToolName do
  @moduledoc """
  Encodes Synapsis tool names for provider APIs with restricted function names.
  """

  @prefix "syn_"
  @openai_safe ~r/^[A-Za-z0-9_-]+$/

  def encode(name) when is_binary(name) do
    if openai_safe?(name) do
      name
    else
      @prefix <> Base.url_encode64(name, padding: false)
    end
  end

  def encode(name), do: encode(to_string(name))

  def decode(@prefix <> encoded = name) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} ->
        if String.valid?(decoded) and not openai_safe?(decoded), do: decoded, else: name

      :error ->
        name
    end
  end

  def decode(name) when is_binary(name), do: name
  def decode(name), do: to_string(name)

  def openai_safe?(name) when is_binary(name), do: Regex.match?(@openai_safe, name)
  def openai_safe?(_name), do: false
end
