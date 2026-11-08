defmodule Synapsis.Agent.Resolver do
  @moduledoc """
  Resolves agent configuration by loading from database first,
  falling back to hardcoded defaults if not found.
  """

  alias Synapsis.{
    AgentConfig,
    AgentConfigs,
    AgentSkills,
    Config.Store,
    SkillCatalog,
    SkillDiscovery
  }

  def resolve(agent_name, project_config \\ %{}) do
    name = to_string(agent_name)

    agent =
      case Enum.find(Store.list(:agent), &(&1["name"] == name)) do
        raw when is_map(raw) ->
          from_db(raw)

        nil ->
          name
          |> default_name()
          |> AgentConfigs.default_attrs()
          |> from_default()
      end

    agent
    |> apply_project_agent_config(project_config)
    |> snapshot_skills()
  end

  @doc "Resolve a saved Agent without the legacy missing-name fallback."
  def resolve_configured(agent_name, project_config \\ %{}) do
    case Enum.find(Store.list(:agent), &(&1["name"] == to_string(agent_name))) do
      raw when is_map(raw) ->
        agent =
          raw |> from_db() |> apply_project_agent_config(project_config) |> snapshot_skills()

        cond do
          not agent.enabled -> {:error, :agent_unavailable}
          Map.has_key?(agent, :skill_discovery_error) -> {:error, agent.skill_discovery_error}
          true -> {:ok, agent}
        end

      nil ->
        {:error, :agent_unavailable}
    end
  end

  @doc "List all available agent names from the database."
  def list_agents do
    AgentConfigs.list_enabled()
  end

  defp from_db(raw) do
    # Keep names, links and the uncast version from one source snapshot. Ecto
    # accepts values such as "1" that are not explicit native provenance.
    config =
      case raw["config"] do
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            _ -> raw["config"]
          end

        config ->
          config
      end

    ac =
      %AgentConfig{}
      |> AgentConfig.changeset(Map.put(raw, "config", config))
      |> Ecto.Changeset.apply_changes()

    selection = %{
      tools: raw["tools"] || [],
      toolset_id: raw["toolset_id"],
      toolset_ids: raw["toolset_ids"] || [],
      tool_contract_version: Map.get(raw, "tool_contract_version", 0)
    }

    model_tier =
      case ac.model_tier do
        "fast" -> :fast
        "expert" -> :expert
        _ -> :default
      end

    %{
      id: raw["id"],
      name: ac.name,
      label: ac.label || String.capitalize(ac.name),
      icon: ac.icon || "robot-outline",
      description: ac.description || "",
      model: ac.model,
      provider: ac.provider,
      system_prompt: ac.system_prompt || default_system_prompt(),
      toolset_id: selection.toolset_id,
      toolset_ids: selected_toolset_ids(selection),
      skills: AgentSkills.list_skills_for_agent(ac),
      workspace_path: workspace_path(ac.name, ac.config),
      reasoning_effort: ac.reasoning_effort || "medium",
      read_only: ac.read_only || false,
      max_tokens: ac.max_tokens || 8192,
      model_tier: model_tier,
      permission_mode: ac.permission_mode || "yolo",
      fallback_models: ac.fallback_models || "",
      is_default: ac.is_default || false,
      enabled: ac.enabled,
      mcp_resource_source_ids: Map.get(ac.config || %{}, "mcp_resource_source_ids", []),
      deferred_tool_names: Map.get(ac.config || %{}, "deferred_tool_names", [])
    }
    |> Map.merge(resolve_tools(selection))
    |> Map.update!(
      :tool_selection_sources,
      &Map.put(&1, "agent", agent_source(raw, selection, config))
    )
    |> maybe_mcp_selection(ac.config)
  end

  defp maybe_mcp_selection(agent, config) do
    case Map.fetch(config || %{}, "mcp_selection") do
      {:ok, policy} -> Map.put(agent, :mcp_selection, policy)
      :error -> agent
    end
  end

  defp from_default(attrs) when is_map(attrs) do
    %{
      name: attrs.name,
      label: attrs.label,
      icon: attrs.icon,
      description: attrs.description,
      model: Map.get(attrs, :model),
      provider: Map.get(attrs, :provider),
      system_prompt: attrs.system_prompt,
      tools: attrs.tools,
      toolset_id: Map.get(attrs, :toolset_id),
      toolset_ids: Map.get(attrs, :toolset_ids, []),
      skills: Map.get(attrs, :skills, []),
      workspace_path: workspace_path(attrs.name, Map.get(attrs, :config, %{})),
      reasoning_effort: attrs.reasoning_effort,
      read_only: attrs.read_only,
      max_tokens: attrs.max_tokens,
      model_tier: model_tier(Map.get(attrs, :model_tier)),
      permission_mode: Map.get(attrs, :permission_mode) || "yolo",
      fallback_models: Map.get(attrs, :fallback_models, ""),
      is_default: attrs.is_default,
      enabled: attrs.enabled,
      mcp_resource_source_ids:
        Map.get(Map.get(attrs, :config, %{}) || %{}, "mcp_resource_source_ids", []),
      deferred_tool_names: Map.get(Map.get(attrs, :config, %{}) || %{}, "deferred_tool_names", [])
    }
    |> Map.merge(resolve_tools(attrs))
  end

  defp from_default(nil), do: "main" |> AgentConfigs.default_attrs() |> from_default()

  defp apply_project_agent_config(agent, project_config) when is_map(project_config) do
    config = project_agent_config(project_config, agent.name)

    agent
    |> fill_blank(:provider, config["provider"])
    |> fill_blank(:model, config["model"])
    |> Map.put(:skill_settings, Map.get(project_config, "skills", %{}))
  end

  defp apply_project_agent_config(agent, _project_config), do: agent

  defp snapshot_skills(agent) do
    case refresh_skills(agent) do
      {:ok, captured} -> captured
      {:error, reason} -> Map.put(agent, :skill_discovery_error, reason)
    end
  end

  @doc "Capture the prompt catalog and native reader snapshot as one immutable pair."
  def refresh_skills(%{id: id} = agent) when is_binary(id) do
    execution = %{deadline: System.monotonic_time(:millisecond) + 5_000}

    with {:ok, snapshot} <- SkillDiscovery.capture(id, execution) do
      {:ok,
       agent
       |> Map.delete(:skill_discovery_error)
       |> Map.put(:skill_snapshot, snapshot)
       |> Map.put(:skill_catalog, SkillDiscovery.entries(snapshot))
       |> Map.put(:skill_loader, Application.get_env(:synapsis_core, :skill_loader))}
    end
  end

  def refresh_skills(agent) when is_map(agent) do
    {:ok,
     agent
     |> Map.put(:skill_catalog, SkillCatalog.snapshot(agent[:skills] || []))
     |> Map.put(:skill_loader, Application.get_env(:synapsis_core, :skill_loader))}
  end

  defp project_agent_config(config, agent_name) do
    agents = config["agents"] || %{}
    name = to_string(agent_name || "main")

    base =
      if name == "main" do
        Map.get(agents, "default", %{})
      else
        %{}
      end

    exact = Map.get(agents, name, %{})

    Map.merge(base, exact, fn _key, base_value, exact_value ->
      if blank?(exact_value), do: base_value, else: exact_value
    end)
  end

  defp fill_blank(agent, _key, value) when value in [nil, ""], do: agent

  defp fill_blank(agent, key, value) do
    case Map.get(agent, key) do
      current when current in [nil, ""] -> Map.put(agent, key, value)
      _current -> agent
    end
  end

  defp default_name("main"), do: "main"
  defp default_name(_name), do: "main"

  defp resolve_tools(%{} = agent) do
    case selected_toolset_ids(agent) do
      [] ->
        selection = %{
          tools: Map.get(agent, :tools) || [],
          tool_contract_version: Map.get(agent, :tool_contract_version, 0),
          tool_selection_sources: %{"toolsets" => []}
        }

        cond do
          selection.tool_contract_version !== 1 ->
            Map.put(
              selection,
              :tool_selection_error,
              {:unsupported_tool_contract_version, selection.tool_contract_version}
            )

          not is_list(selection.tools) ->
            Map.put(selection, :tool_selection_error, :invalid_tool_selection)

          true ->
            selection
        end

      ids ->
        by_id = Map.new(Store.list(:toolset), &{&1["id"], &1})
        missing = Enum.reject(ids, &Map.has_key?(by_id, &1))

        case missing do
          [] ->
            toolsets = Enum.map(ids, &Map.fetch!(by_id, &1))
            versions = Enum.map(toolsets, &{&1["id"], Map.get(&1, "tool_contract_version", 0)})
            invalid = Enum.reject(versions, fn {_id, version} -> version === 1 end)
            names = Enum.map(toolsets, &(&1["tool_names"] || []))

            selection = %{
              tools:
                if(Enum.all?(names, &is_list/1),
                  do: names |> Enum.flat_map(& &1) |> Enum.uniq(),
                  else: []
                ),
              tool_contract_version: if(invalid == [], do: 1),
              tool_selection_sources: %{"toolsets" => Enum.map(toolsets, &toolset_source/1)}
            }

            cond do
              invalid != [] ->
                Map.put(
                  selection,
                  :tool_selection_error,
                  {:unsupported_tool_contract_versions, invalid}
                )

              not Enum.all?(names, &is_list/1) ->
                Map.put(selection, :tool_selection_error, :invalid_tool_selection)

              true ->
                selection
            end

          missing ->
            %{
              tools: [],
              tool_contract_version: nil,
              tool_selection_error: {:toolsets_unavailable, missing},
              tool_selection_sources: %{"toolsets" => []}
            }
        end
    end
  end

  defp agent_source(raw, selection, config) do
    source = %{
      "id" => raw["id"],
      "name" => raw["name"],
      "tool_contract_version" => selection.tool_contract_version,
      "tool_names" => selection.tools,
      "toolset_ids" => selected_toolset_ids(selection),
      "mcp_resource_source_ids" => Map.get(config || %{}, "mcp_resource_source_ids", []),
      "deferred_tool_names" => Map.get(config || %{}, "deferred_tool_names", [])
    }

    case Map.fetch(config || %{}, "mcp_selection") do
      {:ok, policy} -> Map.put(source, "mcp_selection", policy)
      :error -> source
    end
  end

  defp toolset_source(raw) do
    %{
      "id" => raw["id"],
      "name" => raw["name"],
      "tool_contract_version" => Map.get(raw, "tool_contract_version", 0),
      "tool_names" => raw["tool_names"] || []
    }
  end

  defp selected_toolset_ids(%{toolset_ids: ids}) when is_list(ids) and ids != [] do
    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp selected_toolset_ids(%{toolset_id: id}) when not is_nil(id) and id != "", do: [id]
  defp selected_toolset_ids(_agent), do: []

  defp model_tier("fast"), do: :fast
  defp model_tier("expert"), do: :expert
  defp model_tier(_tier), do: :default

  defp blank?(value), do: value in [nil, ""]

  defp workspace_path(name, config) when is_map(config) do
    case Map.get(config, "workspace_path") || Map.get(config, :workspace_path) do
      path when is_binary(path) and path != "" -> path
      _ -> default_workspace_path(name)
    end
  end

  defp workspace_path(name, _config), do: default_workspace_path(name)

  defp default_workspace_path(name) when is_binary(name) and name != "" do
    "~/.synapsis/agents/#{name}"
  end

  defp default_workspace_path(_name), do: "~/.synapsis/agents/main"

  defp default_system_prompt do
    AgentConfigs.default_attrs("main").system_prompt
  end
end
