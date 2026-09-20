defmodule Synapsis.Provider.ToolName do
  @moduledoc """
  Encodes Synapsis tool names for provider APIs with restricted function names.
  """

  @prefix "syn_"
  @hash_prefix "synh_"
  @aliases_key :__synapsis_tool_name_aliases__
  @max_length 64
  @openai_safe ~r/^[A-Za-z0-9_-]+$/

  def encode(name) when is_binary(name) do
    if passthrough?(name) do
      name
    else
      encoded = @prefix <> Base.url_encode64(name, padding: false)

      if byte_size(encoded) <= @max_length do
        encoded
      else
        @hash_prefix <> Base.url_encode64(:crypto.hash(:sha256, name), padding: false)
      end
    end
  end

  def encode(name), do: encode(to_string(name))

  def decode(@prefix <> encoded = name) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} ->
        if String.valid?(decoded) and not passthrough?(decoded), do: decoded, else: name

      :error ->
        name
    end
  end

  def decode(name) when is_binary(name), do: name
  def decode(name), do: to_string(name)

  def decode(name, aliases) when is_map(aliases) do
    name = to_string(name)
    Map.get(aliases, name, decode(name))
  end

  @doc false
  def put_aliases(request, names) when is_map(request) and is_list(names) do
    aliases =
      Enum.reduce(names, %{}, fn name, aliases ->
        name = to_string(name)
        alias_name = encode(name)

        if alias_name == name or decode(alias_name) == name do
          aliases
        else
          put_alias(aliases, alias_name, name)
        end
      end)

    if map_size(aliases) == 0 do
      request
    else
      Map.put(request, @aliases_key, aliases)
    end
  end

  @doc false
  def pop_aliases(request) when is_map(request) do
    case Map.pop(request, @aliases_key, %{}) do
      {aliases, request} -> {request, aliases}
    end
  end

  def openai_safe?(name) when is_binary(name) do
    byte_size(name) <= @max_length and Regex.match?(@openai_safe, name)
  end

  def openai_safe?(_name), do: false

  defp passthrough?(name) do
    openai_safe?(name) and not String.starts_with?(name, [@prefix, @hash_prefix])
  end

  defp put_alias(aliases, alias_name, name) do
    case aliases do
      %{^alias_name => ^name} ->
        aliases

      %{^alias_name => other} ->
        raise ArgumentError, "tool name alias collision: #{name} and #{other}"

      %{} ->
        Map.put(aliases, alias_name, name)
    end
  end
end
