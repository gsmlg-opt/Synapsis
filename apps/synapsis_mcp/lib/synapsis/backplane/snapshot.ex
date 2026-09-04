defmodule Synapsis.Backplane.Snapshot do
  @moduledoc """
  Normalized, process-free view of one Backplane capability source.

  External identities are derived only from Backplane-owned identifiers. Local
  display names and cached artifact ids are deliberately excluded so a rename
  cannot create duplicate imports.
  """

  alias Synapsis.Backplane.Connection

  defstruct [
    :connection,
    :fetched_at,
    :source_revision,
    providers: [],
    models: [],
    skills: [],
    mcp_servers: [],
    mcp_tools: [],
    other_capabilities: [],
    surface_revisions: %{},
    errors: %{}
  ]

  @type capability :: %{
          source: String.t(),
          connection_id: String.t(),
          external_id: String.t(),
          external_revision: String.t(),
          name: String.t(),
          kind: String.t(),
          enabled_by_source: boolean(),
          metadata: map()
        }

  @type t :: %__MODULE__{}

  @spec normalize(Connection.t(), map(), keyword()) :: {:ok, t()}
  def normalize(%Connection{} = connection, surfaces, opts \\ []) when is_map(surfaces) do
    fetched_at = Keyword.get_lazy(opts, :fetched_at, &now/0)

    {models, providers, model_revision, model_error} =
      normalize_models(connection, surface(surfaces, :models))

    {skills, skill_revision, skill_error} =
      normalize_capability_list(connection, "skill", surface(surfaces, :skills), &skill_id/1)

    {mcp_tools, mcp_servers, mcp_revision, mcp_error} =
      normalize_mcp(connection, surface(surfaces, :mcp_tools))

    {other, other_revision, other_error} =
      normalize_capability_list(
        connection,
        "other",
        surface(surfaces, :other_capabilities, {:ok, []}),
        &generic_id/1
      )

    surface_results = [
      models: {model_revision, model_error},
      skills: {skill_revision, skill_error},
      mcp_tools: {mcp_revision, mcp_error},
      other_capabilities: {other_revision, other_error}
    ]

    surface_revisions =
      Enum.reduce(surface_results, %{}, fn
        {name, {revision, nil}}, acc -> Map.put(acc, name, revision)
        {_name, {_revision, _error}}, acc -> acc
      end)

    errors =
      Enum.reduce(surface_results, %{}, fn
        {name, {_revision, error}}, acc when not is_nil(error) -> Map.put(acc, name, error)
        {_name, {_revision, nil}}, acc -> acc
      end)

    # Keep the three first-class discovery surfaces visible without noise from
    # the empty optional extension surface.
    surface_revisions =
      if surface(surfaces, :other_capabilities, :missing) == :missing,
        do: Map.delete(surface_revisions, :other_capabilities),
        else: surface_revisions

    {:ok,
     %__MODULE__{
       connection: Connection.redacted(connection),
       providers: providers,
       models: models,
       skills: skills,
       mcp_servers: mcp_servers,
       mcp_tools: mcp_tools,
       other_capabilities: other,
       fetched_at: fetched_at,
       source_revision: revision(surface_revisions),
       surface_revisions: surface_revisions,
       errors: errors
     }}
  end

  @doc "Returns a lowercase canonical SHA-256 for maps, lists, and scalar values."
  @spec revision(term()) :: String.t()
  def revision(value) do
    value
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_models(connection, {:ok, models}) when is_list(models) do
    with {:ok, capabilities} <- capabilities(connection, "model", models, &model_id/1) do
      revision = collection_revision(models)

      provider =
        capability(
          connection,
          "openai-compatible",
          revision,
          "Backplane #{connection.name}",
          "provider",
          true,
          %{"endpoint" => connection.endpoint, "protocol" => "openai-compatible"}
        )

      {capabilities, [provider], revision, nil}
    else
      {:error, reason} -> {[], [], nil, reason}
    end
  end

  defp normalize_models(_connection, {:error, reason}), do: {[], [], nil, reason}
  defp normalize_models(_connection, other), do: {[], [], nil, {:invalid_models, other}}

  defp normalize_mcp(connection, {:ok, tools}) when is_list(tools) do
    with {:ok, capabilities} <- capabilities(connection, "mcp_tool", tools, &tool_id/1) do
      revision = collection_revision(tools)

      server =
        capability(
          connection,
          "mcp",
          revision,
          "Backplane #{connection.name}",
          "mcp_server",
          true,
          %{"endpoint" => connection.endpoint <> "/mcp", "transport" => "streamable_http"}
        )

      {capabilities, [server], revision, nil}
    else
      {:error, reason} -> {[], [], nil, reason}
    end
  end

  defp normalize_mcp(_connection, {:error, reason}), do: {[], [], nil, reason}
  defp normalize_mcp(_connection, other), do: {[], [], nil, {:invalid_mcp_tools, other}}

  defp normalize_capability_list(connection, kind, {:ok, entries}, id_fun)
       when is_list(entries) do
    case capabilities(connection, kind, entries, id_fun) do
      {:ok, normalized} -> {normalized, collection_revision(entries), nil}
      {:error, reason} -> {[], nil, reason}
    end
  end

  defp normalize_capability_list(_connection, _kind, {:error, reason}, _id_fun),
    do: {[], nil, reason}

  defp normalize_capability_list(_connection, kind, other, _id_fun),
    do: {[], nil, {:invalid_surface, kind, other}}

  defp capabilities(connection, kind, entries, id_fun) do
    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen_ids} ->
      with true <- is_map(entry),
           id when is_binary(id) and id != "" <- id_fun.(entry) do
        if MapSet.member?(seen_ids, id) do
          {:halt, {:error, {:duplicate_capability, kind, id}}}
        else
          name = capability_name(entry, id)

          normalized =
            capability(
              connection,
              id,
              external_revision(entry),
              name,
              kind,
              map_value(entry, "enabled") != false,
              stringify_keys(entry)
            )

          {:cont, {:ok, [normalized | acc], MapSet.put(seen_ids, id)}}
        end
      else
        _invalid -> {:halt, {:error, {:invalid_capability, kind}}}
      end
    end)
    |> case do
      {:ok, normalized, _seen_ids} -> {:ok, Enum.sort_by(normalized, & &1.external_id)}
      error -> error
    end
  end

  defp capability(connection, id, external_revision, name, kind, enabled, metadata) do
    %{
      source: "backplane",
      connection_id: connection.id,
      external_id: id,
      external_revision: external_revision,
      name: name,
      kind: kind,
      enabled_by_source: enabled,
      metadata: metadata
    }
  end

  defp external_revision(entry) do
    upstream =
      map_value(entry, "content_hash") || map_value(entry, "revision") ||
        map_value(entry, "source_revision")

    case upstream do
      value when is_binary(value) -> normalize_revision(value)
      _missing -> revision(entry)
    end
  end

  defp normalize_revision(value) do
    normalized = String.downcase(value)

    if Regex.match?(~r/^[a-f0-9]{64}$/, normalized),
      do: normalized,
      else: revision({:upstream_revision, value})
  end

  defp model_id(model), do: map_value(model, "id")
  defp skill_id(skill), do: map_value(skill, "id") || map_value(skill, "slug")
  defp tool_id(tool), do: map_value(tool, "name")
  defp generic_id(capability), do: map_value(capability, "id") || map_value(capability, "name")

  defp capability_name(entry, fallback) do
    case map_value(entry, "name") do
      name when is_binary(name) -> if String.trim(name) == "", do: fallback, else: name
      _invalid -> fallback
    end
  end

  defp surface(surfaces, name, default \\ nil) do
    Map.get(surfaces, name, Map.get(surfaces, Atom.to_string(name), default))
  end

  defp map_value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(list) when is_list(list) do
    Enum.map(list, &canonical_term/1)
  end

  defp canonical_term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> canonical_term()

  defp canonical_term(value), do: value

  defp collection_revision(entries) do
    entries
    |> Enum.map(&canonical_term/1)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
    |> revision()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
