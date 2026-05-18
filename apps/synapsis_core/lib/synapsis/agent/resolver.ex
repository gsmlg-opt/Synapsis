defmodule Synapsis.Agent.Resolver do
  @moduledoc """
  Resolves agent configuration by loading from database first,
  falling back to hardcoded defaults if not found.
  """

  alias Synapsis.{AgentConfigs, AgentSkills, Toolset, Toolsets}

  def resolve(agent_name, project_config \\ %{}) do
    name = to_string(agent_name)

    agent =
      case AgentConfigs.get_by_name(name) do
        %Synapsis.AgentConfig{} = ac ->
          from_db(ac)

        nil ->
          name
          |> default_name()
          |> AgentConfigs.default_attrs()
          |> from_default()
      end

    apply_project_agent_config(agent, project_config)
  end

  @doc "List all available agent names from the database."
  def list_agents do
    AgentConfigs.list_enabled()
  end

  defp from_db(ac) do
    model_tier =
      case ac.model_tier do
        "fast" -> :fast
        "expert" -> :expert
        _ -> :default
      end

    %{
      name: ac.name,
      label: ac.label || String.capitalize(ac.name),
      icon: ac.icon || "robot-outline",
      description: ac.description || "",
      model: ac.model,
      provider: ac.provider,
      system_prompt: ac.system_prompt || default_system_prompt(),
      tools: resolve_tools(ac),
      toolset_id: ac.toolset_id,
      skills: AgentSkills.list_skills_for_agent(ac),
      workspace_path: workspace_path(ac.name, ac.config),
      reasoning_effort: ac.reasoning_effort || "medium",
      read_only: ac.read_only || false,
      max_tokens: ac.max_tokens || 8192,
      model_tier: model_tier,
      fallback_models: ac.fallback_models || "",
      is_default: ac.is_default || false,
      enabled: ac.enabled
    }
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
      skills: Map.get(attrs, :skills, []),
      workspace_path: workspace_path(attrs.name, Map.get(attrs, :config, %{})),
      reasoning_effort: attrs.reasoning_effort,
      read_only: attrs.read_only,
      max_tokens: attrs.max_tokens,
      model_tier: model_tier(Map.get(attrs, :model_tier)),
      fallback_models: Map.get(attrs, :fallback_models, ""),
      is_default: attrs.is_default,
      enabled: attrs.enabled
    }
  end

  defp from_default(nil), do: "main" |> AgentConfigs.default_attrs() |> from_default()

  defp apply_project_agent_config(agent, project_config) when is_map(project_config) do
    config = project_agent_config(project_config, agent.name)

    agent
    |> fill_blank(:provider, config["provider"])
    |> fill_blank(:model, config["model"])
  end

  defp apply_project_agent_config(agent, _project_config), do: agent

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

  defp resolve_tools(%{toolset_id: nil, tools: tools}), do: tools || []

  defp resolve_tools(%{toolset_id: toolset_id, tools: tools}) do
    case Toolsets.get(toolset_id) do
      %Toolset{tool_names: tool_names} -> tool_names || []
      nil -> tools || []
    end
  end

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
