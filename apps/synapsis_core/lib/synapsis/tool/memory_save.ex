defmodule Synapsis.Tool.MemorySave do
  @moduledoc "Persist semantic memory records. Scope defaults to calling agent's natural scope."
  use Synapsis.Tool

  @impl true
  def name, do: "memory_save"

  @impl true
  def description,
    do:
      "Save one or more semantic memory records (facts, decisions, lessons, preferences, patterns)."

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :memory

  @impl true
  def side_effects, do: [:memory_promoted]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "memories" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "scope" => %{
                "type" => "string",
                "enum" => ["shared", "project", "agent"],
                "description" => "Memory scope (defaults to agent's natural scope)"
              },
              "kind" => %{
                "type" => "string",
                "enum" => ["fact", "decision", "lesson", "preference", "pattern", "warning"],
                "description" => "Memory kind"
              },
              "title" => %{
                "type" => "string",
                "description" => "Short title (~10 words max)"
              },
              "summary" => %{
                "type" => "string",
                "description" => "Compact summary (1-3 sentences, max 200 tokens)"
              },
              "tags" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Tags for categorization"
              },
              "importance" => %{
                "type" => "number",
                "description" => "Importance score 0.0-1.0 (default 0.7)"
              }
            },
            "required" => ["kind", "title", "summary"]
          },
          "description" => "Array of memory records to save"
        }
      },
      "required" => ["memories"]
    }
  end

  @impl true
  def execute(input, context) do
    memories = Map.get(input, "memories", [])
    agent_id = Map.get(context, :agent_id, "unknown")
    project_id = Map.get(context, :project_id, "")
    agent_scope = Map.get(context, :agent_scope, :project)

    results =
      Enum.map(memories, fn mem ->
        scope = Map.get(mem, "scope") || infer_scope(agent_scope)
        scope_id = scope_id_for(scope, project_id, agent_id)

        attrs = %{
          scope: scope,
          scope_id: scope_id,
          kind: Map.get(mem, "kind"),
          title: Map.get(mem, "title"),
          summary: Map.get(mem, "summary"),
          tags: Map.get(mem, "tags", []),
          importance: Map.get(mem, "importance", 0.7),
          confidence: 0.8,
          freshness: 1.0,
          source: "agent",
          contributed_by: agent_id
        }

        case Synapsis.Memory.store_semantic(attrs) do
          {:ok, record} ->
            # Broadcast for cache invalidation and UI updates
            broadcast_memory_promoted(scope, scope_id, record.id)
            %{id: record.id, title: record.title, status: "saved"}

          {:error, _changeset} ->
            %{title: Map.get(mem, "title"), status: "error", error: "validation failed"}
        end
      end)

    {:ok, Jason.encode!(results)}
  end

  defp infer_scope(:agent), do: "agent"
  defp infer_scope(:shared), do: "shared"
  defp infer_scope(_), do: "project"

  defp scope_id_for("shared", _, _), do: ""
  defp scope_id_for("project", project_id, _), do: project_id
  defp scope_id_for("agent", _, agent_id), do: agent_id
  defp scope_id_for(_, project_id, _), do: project_id

  defp broadcast_memory_promoted(scope, scope_id, memory_id) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "memory:#{scope}:#{scope_id}",
      {:memory_promoted, memory_id}
    )

    Synapsis.Memory.Cache.invalidate(scope, scope_id)
  end
end
