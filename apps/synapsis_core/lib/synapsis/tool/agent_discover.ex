defmodule Synapsis.Tool.AgentDiscover do
  @moduledoc "Query running agents from OTP registry."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_discover"

  @impl true
  def description,
    do: "Discover running agents. List all, get a specific agent, or find agents by project."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "get", "find_by_project"],
          "description" => "Discovery action"
        },
        "agent_id" => %{"type" => "string", "description" => "Agent ID (for 'get' action)"},
        "project_id" => %{
          "type" => "string",
          "description" => "Project ID (for 'find_by_project')"
        },
        "type" => %{"type" => "string", "description" => "Optional agent type filter"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def execute(input, _context) do
    case input["action"] do
      "list" -> list_agents(input["type"])
      "get" -> get_agent(input["agent_id"])
      "find_by_project" -> find_by_project(input["project_id"])
      other -> {:error, "Unknown action: #{other}"}
    end
  end

  defp list_agents(type_filter) do
    agents =
      Registry.select(Synapsis.Session.Registry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.map(fn {key, pid, value} ->
        %{
          "id" => to_string(key),
          "pid" => inspect(pid),
          "alive" => Process.alive?(pid),
          "info" => format_value(value)
        }
      end)
      |> maybe_filter_type(type_filter)

    {:ok, Jason.encode!(%{agents: agents, count: length(agents)})}
  rescue
    _e in [ArgumentError, RuntimeError] ->
      {:ok, Jason.encode!(%{agents: [], count: 0, note: "Registry not available"})}
  end

  defp get_agent(nil), do: {:error, "agent_id is required for 'get' action"}

  defp get_agent(agent_id) do
    case Registry.lookup(Synapsis.Session.Registry, agent_id) do
      [{pid, value}] ->
        {:ok,
         Jason.encode!(%{
           id: agent_id,
           pid: inspect(pid),
           alive: Process.alive?(pid),
           info: format_value(value)
         })}

      [] ->
        {:ok, Jason.encode!(%{id: agent_id, found: false})}
    end
  end

  defp find_by_project(nil), do: {:error, "project_id is required for 'find_by_project'"}

  defp find_by_project(project_id) do
    agents =
      Registry.select(Synapsis.Session.Registry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.filter(fn {_key, _pid, value} ->
        is_map(value) and Map.get(value, :project_id) == project_id
      end)
      |> Enum.map(fn {key, pid, _value} ->
        %{"id" => to_string(key), "pid" => inspect(pid), "alive" => Process.alive?(pid)}
      end)

    {:ok, Jason.encode!(%{agents: agents, count: length(agents), project_id: project_id})}
  rescue
    _e in [ArgumentError, RuntimeError] ->
      {:ok, Jason.encode!(%{agents: [], count: 0, project_id: project_id})}
  end

  defp format_value(value) when is_map(value), do: inspect(value)
  defp format_value(value), do: to_string(value)

  defp maybe_filter_type(agents, nil), do: agents

  defp maybe_filter_type(agents, type) do
    Enum.filter(agents, fn a -> String.contains?(a["info"] || "", type) end)
  end
end
