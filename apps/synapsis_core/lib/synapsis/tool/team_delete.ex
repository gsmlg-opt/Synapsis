defmodule Synapsis.Tool.TeamDelete do
  @moduledoc "Dissolve the swarm team, terminating all teammates."
  use Synapsis.Tool

  @impl true
  def name, do: "team_delete"

  @impl true
  def description, do: "Dissolve the team and terminate all teammate agents."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :swarm

  @impl true
  def execute(_input, context) do
    session_id = context[:session_id]

    if is_nil(session_id) do
      {:error, "No session context for team deletion"}
    else
      teammates = Process.get({:swarm_teammates, session_id}, %{})
      count = map_size(teammates)
      Process.delete({:swarm_teammates, session_id})

      {:ok, "Team dissolved. #{count} teammate(s) terminated."}
    end
  end
end
