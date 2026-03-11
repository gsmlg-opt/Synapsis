defmodule Synapsis.Tool.MemorySearch do
  @moduledoc "Search semantic memory. Retrieval walks up the scope hierarchy."
  use Synapsis.Tool

  @impl true
  def name, do: "memory_search"

  @impl true
  def description,
    do:
      "Search semantic memory for prior knowledge, decisions, lessons, and patterns. Returns ranked results."

  @impl true
  def permission_level, do: :read

  @impl true
  def category, do: :memory

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query for memory retrieval"
        },
        "scope" => %{
          "type" => "string",
          "enum" => ["shared", "project", "agent"],
          "description" => "Starting scope (defaults to agent's scope, walks up)"
        },
        "kinds" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Filter by memory kinds: fact, decision, lesson, preference, pattern, warning"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Filter by tags"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default 5)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(input, context) do
    query = Map.get(input, "query", "")

    opts = %{
      query: query,
      scope: parse_scope(Map.get(input, "scope"), context),
      agent_id: Map.get(context, :agent_id),
      project_id: Map.get(context, :project_id, ""),
      kinds: Map.get(input, "kinds"),
      tags: Map.get(input, "tags"),
      limit: Map.get(input, "limit", 5)
    }

    results = Synapsis.Memory.Retriever.retrieve(opts)

    formatted =
      Enum.map(results, fn mem ->
        %{
          id: mem.id,
          kind: mem.kind,
          title: mem.title,
          summary: mem.summary,
          scope: mem.scope,
          tags: mem.tags,
          contributed_by: mem.contributed_by,
          score: mem.score
        }
      end)

    {:ok, Jason.encode!(formatted)}
  end

  defp parse_scope(nil, context), do: Map.get(context, :agent_scope, :project)
  defp parse_scope("shared", _), do: :shared
  defp parse_scope("project", _), do: :project
  defp parse_scope("agent", _), do: :agent
  defp parse_scope(_, context), do: Map.get(context, :agent_scope, :project)
end
