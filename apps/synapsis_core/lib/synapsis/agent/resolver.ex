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

  defp hardcoded_default(_name) do
    %{
      name: "main",
      label: "Main",
      icon: "robot-outline",
      description: "AI coding assistant with full workspace access, tools, and memory.",
      model: nil,
      provider: nil,
      system_prompt: default_system_prompt(),
      tools: [
        "file_read",
        "file_edit",
        "file_write",
        "multi_edit",
        "file_delete",
        "file_move",
        "list_dir",
        "grep",
        "glob",
        "bash",
        "fetch",
        "web_search",
        "todo_read",
        "todo_write",
        "enter_plan_mode",
        "exit_plan_mode",
        "task",
        "skill",
        "tool_search",
        "ask_user",
        "sleep",
        "memory_save",
        "memory_search",
        "memory_update",
        "session_summarize",
        "board_read",
        "board_update",
        "devlog_read",
        "devlog_write",
        "repo_link",
        "repo_status",
        "repo_sync",
        "worktree_create",
        "worktree_list",
        "worktree_remove",
        "diagnostics"
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
