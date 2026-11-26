defmodule Synapsis.Backplane.SkillDiscovery do
  @moduledoc "Session discovery that never imports, assigns or reconciles source records."

  alias Synapsis.Backplane.{Client, Connection}
  alias Synapsis.{AgentConfigs, SkillCatalog, SkillReader}

  @timeout 5_000

  def always(agent_id, snapshot) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    Enum.reduce(source_ids(agent_id), %{sources: [], errors: %{}}, fn id, result ->
      with {:ok, timeout} <- remaining_timeout(deadline),
           {:ok, source} <- source(agent_id, id),
           {:ok, descriptors, partial?} <-
             Client.list_protocol_skills(source,
               view: :always,
               max_skills: 1_000,
               timeout: timeout
             ) do
        entries =
          source.id
          |> SkillCatalog.remote_entries(descriptors)
          |> Enum.filter(&(&1.enabled and &1.prompt_visible))
          |> Enum.map(fn entry ->
            suffix =
              if readable?(entry, snapshot),
                do: "",
                else: " (Agent assignment required before reading)"

            %{entry | description: (entry.description || "") <> suffix}
          end)

        item = %{id: source.id, name: source.name, entries: entries, partial: partial?}
        %{result | sources: result.sources ++ [item]}
      else
        {:error, reason} -> %{result | errors: Map.put(result.errors, id, error_code(reason))}
      end
    end)
  end

  def search(agent_id, snapshot, source_id, query, opts \\ []) do
    with {:ok, source} <- source(agent_id, source_id),
         {:ok, %{data: descriptors, next_cursor: cursor}} <-
           Client.search_protocol_skills(source, query, opts) do
      results =
        source.id
        |> SkillCatalog.remote_entries(descriptors)
        |> Enum.filter(&(&1.enabled and &1.prompt_visible))
        |> Enum.map(fn entry ->
          readable = readable?(entry, snapshot)

          %{
            source_authority: "backplane",
            source_id: entry.source_id,
            skill_id: entry.skill_id,
            revision: entry.revision,
            artifact_digest: entry.artifact_digest,
            name: entry.name,
            description: entry.description,
            locator: entry.locator,
            readable: readable,
            assignment_required: not readable
          }
        end)

      {:ok, %{results: results, truncated: not is_nil(cursor), next_cursor: cursor}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  def create(agent_id, source_id, attributes, opts \\ []) do
    with {:ok, source} <- source(agent_id, source_id),
         {:ok, manifest} <- Client.create_protocol_skill(source, attributes, opts) do
      [entry] =
        SkillCatalog.remote_entries(source.id, [
          %{
            "id" => manifest.ref.skill_id,
            "name" => attributes["name"],
            "revision" => manifest.ref.revision,
            "artifact_digest" => manifest.ref.artifact_digest,
            "enabled" => false
          }
        ])

      {:ok,
       %{
         source_id: source.id,
         skill_id: manifest.ref.skill_id,
         revision: manifest.ref.revision,
         artifact_digest: manifest.ref.artifact_digest,
         locator: entry.locator
       }}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp remaining_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _ -> {:error, {:skill_protocol, :timeout}}
    end
  end

  defp source_ids(agent_id) do
    case AgentConfigs.get(agent_id) do
      %{enabled: true, config: config} ->
        case Map.get(config || %{}, "backplane_skill_source_ids", []) do
          ids when is_list(ids) ->
            if Enum.all?(ids, &is_binary/1), do: Enum.uniq(ids), else: []

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp source(agent_id, source_id) do
    with true <- source_id in source_ids(agent_id),
         {:ok, connection} <- Connection.get(source_id),
         true <- connection.enabled and Connection.surface_enabled?(connection, "skills"),
         {:ok, connection} <- Connection.runtime(connection) do
      {:ok, connection}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp readable?(entry, snapshot) do
    match?({:ok, _}, SkillReader.select(snapshot, entry.locator))
  end

  defp error_code({:skill_protocol, code}) when is_atom(code), do: code
  defp error_code(code) when code in [:source_unavailable, :provider_unavailable], do: code
  defp error_code(_), do: :source_unavailable
end
