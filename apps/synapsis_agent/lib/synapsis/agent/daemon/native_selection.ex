defmodule Synapsis.Agent.Daemon.NativeSelection do
  @moduledoc false

  alias Synapsis.Agent.{Resolver, Runs}
  alias Synapsis.Agent.Daemon.Toolsets
  alias Synapsis.Agent.Tools.{Discovery, MCPSources, Profiles}
  alias Synapsis.Session

  @snapshot_keys ~w(version selection_kind agent_id agent_name tool_names sources)
  @stale_selection [
    :deferred_tool_names,
    :tools,
    :resolved_tools,
    :tool_modules,
    :tool_selection_error,
    :tool_contract_version,
    :tool_selection_sources,
    :mcp_selection,
    :mcp_sources,
    :mcp_resource_source_ids,
    :mcp_resource_sources
  ]

  # Capture only locally published source snapshots in the existing submission
  # task. Descriptors, live authorities and process handles belong to each turn.
  def capture(%{tool_profile: "native_agent", assistant_name: name} = attrs) do
    with {:ok, agent} <- Resolver.resolve_configured(name),
         {:ok, captured} <- MCPSources.capture(agent),
         {:ok, names} <- Profiles.selection(%{agent: captured, session: %Session{config: %{}}}),
         {:ok, _} <- Discovery.plan(captured, names) do
      snapshot = %{
        "version" => 1,
        "selection_kind" => "native_agent",
        "agent_id" => agent.id,
        "agent_name" => agent.name,
        "tool_names" => names,
        "sources" => agent.tool_selection_sources
      }

      {:ok, Map.put(attrs, :capability_snapshot, snapshot)}
    end
  end

  def capture(%{tool_profile: profile, assistant_name: name} = attrs) do
    with {:ok, names} <- Toolsets.resolve(profile),
         {:ok, agent} <- Resolver.resolve_configured(name),
         selected =
           agent
           |> Map.drop(@stale_selection)
           |> Map.put(:tools, names)
           |> Map.put(:tool_contract_version, 1)
           |> Map.put(:deferred_tool_names, [])
           |> Map.put(:mcp_resource_source_ids, []),
         {:ok, names} <- Profiles.selection(%{agent: selected, session: %Session{config: %{}}}),
         {:ok, _} <- Discovery.plan(selected, names) do
      snapshot = %{
        "version" => 1,
        "selection_kind" => "native_profile",
        "agent_id" => agent.id,
        "agent_name" => agent.name,
        "tool_names" => names,
        "sources" => %{
          "agent" => %{"id" => agent.id, "name" => agent.name},
          "profile" => %{
            "name" => profile,
            "tool_contract_version" => 1,
            "tool_names" => names
          }
        }
      }

      {:ok, Map.put(attrs, :capability_snapshot, snapshot)}
    end
  end

  def capture(attrs), do: {:ok, attrs}

  def snapshot(%{
        tool_profile: "native_agent",
        assistant_name: name,
        capability_snapshot: snapshot
      })
      when is_map(snapshot) do
    with true <- Enum.sort(Map.keys(snapshot)) == Enum.sort(@snapshot_keys),
         %{
           "version" => 1,
           "selection_kind" => "native_agent",
           "agent_name" => ^name,
           "agent_id" => id,
           "tool_names" => names,
           "sources" => sources
         } <- snapshot,
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_binary(name) and name != "",
         true <- is_list(names),
         true <- Enum.all?(names, &exact_name?/1) and Enum.uniq(names) == names,
         true <- valid_sources?(sources, id, name),
         {:ok, _} <-
           Discovery.plan(
             %{deferred_tool_names: Map.get(sources["agent"], "deferred_tool_names", [])},
             names
           ) do
      {:ok, snapshot}
    else
      _ -> {:error, :invalid_daemon_native_selection}
    end
  end

  def snapshot(%{
        tool_profile: profile,
        assistant_name: name,
        capability_snapshot: snapshot
      })
      when is_map(snapshot) do
    with true <- Toolsets.profile?(profile),
         true <- Enum.sort(Map.keys(snapshot)) == Enum.sort(@snapshot_keys),
         %{
           "version" => 1,
           "selection_kind" => "native_profile",
           "agent_name" => ^name,
           "agent_id" => id,
           "tool_names" => names,
           "sources" => sources
         } <- snapshot,
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_binary(name) and name != "",
         true <- is_list(names),
         true <- Enum.all?(names, &exact_name?/1) and Enum.uniq(names) == names,
         true <- valid_profile_sources?(sources, id, name, profile, names),
         {:ok, _} <- Discovery.plan(%{deferred_tool_names: []}, names) do
      {:ok, snapshot}
    else
      _ -> {:error, :invalid_daemon_native_selection}
    end
  end

  def snapshot(_), do: {:error, :invalid_daemon_native_selection}

  def overlay(agent, session) do
    with {:ok, _run, snapshot} <- load(session),
         true <- agent[:id] == snapshot["agent_id"] and agent[:enabled] == true do
      agent
      |> Map.drop(@stale_selection)
      |> Map.put(:tools, snapshot["tool_names"])
      |> Map.put(
        :deferred_tool_names,
        Map.get(snapshot["sources"]["agent"], "deferred_tool_names", [])
      )
      |> Map.put(:tool_contract_version, 1)
      |> Map.put(:tool_selection_sources, snapshot["sources"])
      |> Map.put(
        :mcp_resource_source_ids,
        Map.get(snapshot["sources"]["agent"], "mcp_resource_source_ids", [])
      )
    else
      _ ->
        agent
        |> Map.drop(@stale_selection)
        |> Map.put(:tools, [])
        |> Map.put(:tool_contract_version, 0)
        |> Map.put(:tool_selection_error, :invalid_daemon_native_selection)
    end
  end

  # Boot precedes mark_running. Turn admission requires its acknowledged binding,
  # including later turns on the same completed Run's session.
  def validate_association(%Session{config: %{"daemon_run_id" => _}} = session) do
    with {:ok, run, _snapshot} <- load(session),
         true <- run.session_id == session.id do
      :ok
    else
      _ -> {:error, :daemon_session_mismatch}
    end
  end

  def validate_association(_session), do: :ok

  defp load(%Session{
         agent: name,
         config: %{"daemon_run_id" => id, "daemon_run_tool_contract_version" => 1}
       })
       when is_binary(id) do
    with {:ok, %{assistant_name: ^name} = run} <- Runs.fetch(id),
         {:ok, snapshot} <- snapshot(run) do
      {:ok, run, snapshot}
    else
      _ -> {:error, :invalid_daemon_native_selection}
    end
  end

  defp load(_), do: {:error, :invalid_daemon_native_selection}

  defp valid_sources?(
         %{
           "agent" =>
             %{
               "id" => id,
               "name" => name,
               "toolset_ids" => ids,
               "tool_contract_version" => version,
               "tool_names" => tools
             } = agent_source,
           "toolsets" => toolsets
         },
         id,
         name
       )
       when is_list(ids) and is_list(toolsets) and is_list(tools) do
    with {:ok, _} <-
           MCPSources.resource_source_ids(%{
             mcp_resource_source_ids: Map.get(agent_source, "mcp_resource_source_ids", [])
           }) do
      if ids == [] do
        version === 1 and toolsets == []
      else
        Enum.all?(toolsets, fn source ->
          is_map(source) and source["tool_contract_version"] === 1 and
            is_binary(source["name"]) and is_list(source["tool_names"])
        end) and Enum.map(toolsets, & &1["id"]) == ids
      end
    else
      _ -> false
    end
  end

  defp valid_sources?(_, _, _), do: false

  defp valid_profile_sources?(
         %{
           "agent" => %{"id" => id, "name" => name} = agent,
           "profile" =>
             %{
               "name" => profile,
               "tool_contract_version" => 1,
               "tool_names" => names
             } = profile_source
         } = sources,
         id,
         name,
         profile,
         names
       ) do
    Enum.sort(Map.keys(sources)) == ~w(agent profile) and
      Enum.sort(Map.keys(agent)) == ~w(id name) and
      Enum.sort(Map.keys(profile_source)) == ~w(name tool_contract_version tool_names)
  end

  defp valid_profile_sources?(_, _, _, _, _), do: false

  defp exact_name?(name),
    do:
      is_binary(name) and String.trim(name) != "" and
        not String.contains?(name, ["*", "?", "(", ")"])
end
