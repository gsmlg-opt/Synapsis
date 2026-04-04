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
        hardcoded_default(name)
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

  defp hardcoded_default("plan") do
    %{
      name: "plan",
      label: "Plan",
      icon: "clipboard-text-outline",
      description: "Planning assistant that analyzes codebases and creates implementation plans.",
      model: nil,
      provider: nil,
      system_prompt:
        "You are a planning assistant. Analyze the codebase and create implementation plans. Do NOT make changes.",
      tools: ["file_read", "grep", "glob", "diagnostics"],
      reasoning_effort: "high",
      read_only: true,
      max_tokens: 8192,
      model_tier: :expert,
      fallback_models: "",
      is_default: false,
      enabled: true
    }
  end

  defp hardcoded_default("assistant") do
    %{
      name: "assistant",
      label: "Assistant",
      icon: "chat-processing-outline",
      description:
        "Conversational assistant that coordinates work and delegates coding to Build agents.",
      model: nil,
      provider: nil,
      system_prompt: """
      You are Synapsis, a conversational AI assistant. You help users plan, coordinate,
      and manage development work. When the user needs code changes, file edits, or
      shell commands executed, delegate to a coding agent using the task tool.

      You do NOT have direct filesystem access. Use the task tool to spawn a coding
      agent for any work that requires reading files, editing code, or running commands.

      Your strengths: planning, memory management, web research, project coordination.
      """,
      tools: [
        "task",
        "ask_user",
        "web_search",
        "fetch",
        "memory_save",
        "memory_search",
        "memory_update",
        "todo_read",
        "todo_write",
        "board_read",
        "board_update",
        "devlog_read",
        "devlog_write",
        "enter_plan_mode",
        "exit_plan_mode",
        "sleep",
        "skill",
        "tool_search",
        "workspace_read",
        "workspace_write",
        "workspace_list",
        "workspace_search"
      ],
      reasoning_effort: "high",
      read_only: false,
      max_tokens: 8192,
      model_tier: :expert,
      fallback_models: "",
      is_default: false,
      enabled: true
    }
  end

  defp hardcoded_default(_name) do
    %{
      name: "build",
      label: "Build",
      icon: "hammer-wrench",
      description: "Workspace-driven coding assistant with identity, tools, and memory.",
      model: nil,
      provider: nil,
      system_prompt: default_system_prompt(),
      tools: [
        "file_read",
        "file_edit",
        "file_write",
        "bash",
        "grep",
        "glob",
        "diagnostics",
        "fetch"
      ],
      reasoning_effort: "medium",
      read_only: false,
      max_tokens: 8192,
      model_tier: :default,
      fallback_models: "",
      is_default: true,
      enabled: true
    }
  end

  defp default_system_prompt do
    """
    You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
    You have access to tools for reading files, editing files, running shell commands, and searching code.
    Always explain your reasoning before making changes. Be concise and precise.
    """
  end
end
