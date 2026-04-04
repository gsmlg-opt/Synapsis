defmodule Synapsis.Tool.AgentSpawn do
  @moduledoc "Spawn a build agent for a task (stub — Build Agent system not yet implemented)."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_spawn"

  @impl true
  def description,
    do:
      "Spawn a build agent to autonomously work on a task. The agent can create a worktree, " <>
        "run tools, and update the board. (Build Agent system not yet implemented.)"

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:agent_spawned, :board_changed]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "task_id" => %{
          "type" => "string",
          "description" => "Board card ID representing the task to assign to the agent"
        },
        "model" => %{
          "type" => "string",
          "description" => "LLM model to use for the agent"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tool names to make available to the agent"
        },
        "auto_worktree" => %{
          "type" => "boolean",
          "description" => "Automatically create a git worktree for this agent (default true)"
        }
      },
      "required" => ["task_id"]
    }
  end

  @impl true
  def execute(_input, _context) do
    {:error, "Build Agent system not yet implemented. Agent spawning will be available in Phase 5."}
  end
end
