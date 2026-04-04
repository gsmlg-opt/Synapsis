defmodule Synapsis.Tool.AgentStatus do
  @moduledoc "Get status of active build agents (stub — Build Agent system not yet implemented)."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_status"

  @impl true
  def description,
    do:
      "Get status of active build agents, optionally filtered by session_id. " <>
        "(Build Agent system not yet implemented.)"

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{
          "type" => "string",
          "description" => "Filter by agent session ID"
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(_input, _context) do
    {:ok, Jason.encode!(%{agents: [], message: "Build Agent system not yet implemented."})}
  end
end
