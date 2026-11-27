defmodule Synapsis.Provider.ToolName do
  @moduledoc """
  Encodes Synapsis tool names for provider APIs with restricted function names.
  """

  @prefix "syn_"
  @hash_prefix "synh_"
  @aliases_key :__synapsis_tool_name_aliases__
  @skill_tools ~w(skill skill_workshop skills_create skills_read skills_search)
  @max_length 64
  @openai_safe ~r/^[A-Za-z0-9_-]+$/

  def encode("synapsis::" <> skill) when skill in @skill_tools, do: "synapsis__" <> skill

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

  @doc "Freeze provider-safe names for a catalog and its replayed tool calls."
  def wire_names(names, fallback \\ &encode/1) do
    names = Enum.uniq(names)

    sources =
      for "mcp::" <> qualified <- names,
          [id, _raw] <- [String.split(qualified, "::", parts: 2)],
          uniq: true,
          do: id

    source_names =
      Map.new(sources, fn id ->
        config = Synapsis.MCPConfigs.get(id)
        {id, config && Synapsis.MCPConfigs.display_name(config)}
      end)

    candidates = Map.new(names, &{&1, mcp_wire_name(&1, source_names) || fallback.(&1)})
    counts = candidates |> Map.values() |> Enum.frequencies()

    Map.new(candidates, fn {native, wire} ->
      {native, if(counts[wire] > 1, do: fallback.(native), else: wire)}
    end)
  end

  defp mcp_wire_name("mcp::" <> qualified = native, sources) do
    with [id, raw] <- String.split(qualified, "::", parts: 2),
         source when is_binary(source) <- sources[id] do
      readable = String.replace("mcp::#{source}::#{raw}", "::", "__")
      safe = String.replace(readable, ~r/[^A-Za-z0-9_-]/u, "_")

      if safe == readable and byte_size(safe) <= @max_length do
        safe
      else
        suffix =
          :crypto.hash(:sha256, native) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        String.slice(safe, 0, @max_length - 17) <> "_" <> suffix
      end
    else
      _ -> nil
    end
  end

  defp mcp_wire_name(_, _), do: nil

  def decode("synapsis__" <> skill) when skill in @skill_tools, do: "synapsis::" <> skill

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
    put_aliases(request, Map.new(names, &{&1, encode(&1)}))
  end

  def put_aliases(request, wire_names) when is_map(wire_names) do
    aliases =
      Enum.reduce(wire_names, %{}, fn {name, alias_name}, aliases ->
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

  defp passthrough?("synapsis__" <> skill) when skill in @skill_tools, do: false

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
