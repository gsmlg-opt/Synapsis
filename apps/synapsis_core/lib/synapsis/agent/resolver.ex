defmodule Synapsis.Agent.Resolver do
  @moduledoc """
  Resolves agent configuration by loading from database first,
  falling back to hardcoded defaults if not found.
  """

  alias Synapsis.AgentConfigs

  def resolve(agent_name, _project_config \\ %{}) do
    name = to_string(agent_name)

    case AgentConfigs.get_by_name(name) do
      %Synapsis.AgentConfig{} = ac ->
        from_db(ac)

      nil ->
        name
        |> default_name()
        |> AgentConfigs.default_attrs()
        |> from_default()
    end
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
      tools: ac.tools || [],
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
      reasoning_effort: attrs.reasoning_effort,
      read_only: attrs.read_only,
      max_tokens: attrs.max_tokens,
      model_tier: model_tier(Map.get(attrs, :model_tier)),
      fallback_models: Map.get(attrs, :fallback_models, ""),
      is_default: attrs.is_default,
      enabled: attrs.enabled
    }
  end

  defp from_default(nil), do: "build" |> AgentConfigs.default_attrs() |> from_default()

  defp default_name("assistant"), do: "assistant"
  defp default_name("build"), do: "build"
  defp default_name("main"), do: "main"
  defp default_name("plan"), do: "plan"
  defp default_name(_name), do: "build"

  defp model_tier("fast"), do: :fast
  defp model_tier("expert"), do: :expert
  defp model_tier(_tier), do: :default

  defp default_system_prompt do
    AgentConfigs.default_attrs("build").system_prompt
  end
end
