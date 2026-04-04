defmodule Synapsis.Tool.Builtin do
  @moduledoc "Registers all built-in tools on startup."

  @tools [
    # Original tools
    Synapsis.Tool.FileRead,
    Synapsis.Tool.FileEdit,
    Synapsis.Tool.FileWrite,
    Synapsis.Tool.Bash,
    Synapsis.Tool.Grep,
    Synapsis.Tool.Glob,
    Synapsis.Tool.Fetch,
    Synapsis.Tool.Diagnostics,
    Synapsis.Tool.ListDir,
    Synapsis.Tool.FileDelete,
    Synapsis.Tool.FileMove,
    # Phase 5: Multi-edit
    Synapsis.Tool.MultiEdit,
    # Phase 7: Planning & session
    Synapsis.Tool.TodoWrite,
    Synapsis.Tool.TodoRead,
    Synapsis.Tool.EnterPlanMode,
    Synapsis.Tool.ExitPlanMode,
    # Phase 8: Web search
    Synapsis.Tool.WebSearch,
    # Phase 9: User interaction
    Synapsis.Tool.AskUser,
    # Phase 10: Sub-agent tools
    Synapsis.Tool.Task,
    Synapsis.Tool.Skill,
    Synapsis.Tool.Sleep,
    Synapsis.Tool.SendMessage,
    # Phase 11: Tool search
    Synapsis.Tool.ToolSearch,
    # Phase 12: Swarm tools
    Synapsis.Tool.Teammate,
    Synapsis.Tool.TeamDelete,
    # Phase 14: Memory tools
    Synapsis.Tool.SessionSummarize,
    Synapsis.Tool.MemorySave,
    Synapsis.Tool.MemorySearch,
    Synapsis.Tool.MemoryUpdate,
    # Phase 15: Agent communication tools
    Synapsis.Tool.AgentSend,
    Synapsis.Tool.AgentAsk,
    Synapsis.Tool.AgentReply,
    Synapsis.Tool.AgentHandoff,
    Synapsis.Tool.AgentDiscover,
    Synapsis.Tool.AgentInbox,
    # Phase 13: Disabled stubs
    Synapsis.Tool.NotebookEdit,
    Synapsis.Tool.NotebookRead,
    Synapsis.Tool.Computer,
    # Phase N: Workflow tools
    Synapsis.Tool.BoardRead,
    Synapsis.Tool.BoardUpdate,
    Synapsis.Tool.DevlogRead,
    Synapsis.Tool.DevlogWrite,
    Synapsis.Tool.RepoLink,
    Synapsis.Tool.RepoSync,
    Synapsis.Tool.RepoStatus,
    Synapsis.Tool.WorktreeCreate,
    Synapsis.Tool.WorktreeList,
    Synapsis.Tool.WorktreeRemove,
    Synapsis.Tool.AgentSpawn,
    Synapsis.Tool.AgentStatus
  ]

  def register_all do
    for mod <- @tools do
      Synapsis.Tool.Registry.register_module(mod.name(), mod,
        timeout: default_timeout(mod.name()),
        description: mod.description(),
        parameters: mod.parameters()
      )
    end

    :ok
  end

  defp default_timeout("bash"), do: 30_000
  defp default_timeout("fetch"), do: 15_000
  defp default_timeout("web_search"), do: 15_000
  defp default_timeout("multi_edit"), do: 15_000
  defp default_timeout("task"), do: 600_000
  defp default_timeout("grep"), do: 10_000
  defp default_timeout("file_edit"), do: 10_000
  defp default_timeout("file_write"), do: 10_000
  defp default_timeout("file_read"), do: 5_000
  defp default_timeout("glob"), do: 5_000
  defp default_timeout("list_dir"), do: 5_000
  defp default_timeout("file_delete"), do: 5_000
  defp default_timeout("file_move"), do: 5_000
  defp default_timeout("ask_user"), do: 300_000
  defp default_timeout("sleep"), do: 600_000
  defp default_timeout("agent_ask"), do: 300_000
  defp default_timeout("agent_handoff"), do: 30_000
  defp default_timeout(_), do: 10_000
end
