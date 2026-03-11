defmodule Synapsis.Tool.MemoryUpdate do
  @moduledoc "Update, archive, or restore a semantic memory record."
  use Synapsis.Tool

  @impl true
  def name, do: "memory_update"

  @impl true
  def description,
    do: "Update, archive, or restore a semantic memory record. Creates audit trail."

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :memory

  @impl true
  def side_effects, do: [:memory_updated]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["update", "archive", "restore"],
          "description" => "Action to perform"
        },
        "memory_id" => %{
          "type" => "string",
          "description" => "ID of the semantic memory to modify"
        },
        "changes" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "summary" => %{"type" => "string"},
            "kind" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "importance" => %{"type" => "number"},
            "confidence" => %{"type" => "number"}
          },
          "description" => "Changes to apply (for 'update' action)"
        }
      },
      "required" => ["action", "memory_id"]
    }
  end

  @impl true
  def execute(input, context) do
    action = Map.get(input, "action")
    memory_id = Map.get(input, "memory_id")
    agent_id = Map.get(context, :agent_id, "unknown")

    case Synapsis.Memory.get_semantic(memory_id) do
      {:error, :not_found} ->
        {:error, "Memory not found: #{memory_id}"}

      {:ok, memory} ->
        # Record previous state for audit trail
        previous = %{
          title: memory.title,
          summary: memory.summary,
          kind: memory.kind,
          tags: memory.tags,
          importance: memory.importance,
          confidence: memory.confidence,
          archived_at: memory.archived_at
        }

        result =
          case action do
            "update" ->
              changes = Map.get(input, "changes", %{})
              Synapsis.Memory.update_semantic(memory, changes)

            "archive" ->
              Synapsis.Memory.archive_semantic(memory)

            "restore" ->
              Synapsis.Memory.restore_semantic(memory)

            _ ->
              {:error, "Unknown action: #{action}"}
          end

        case result do
          {:ok, updated} ->
            # Audit trail event
            Synapsis.Memory.append_event(%{
              scope: updated.scope,
              scope_id: updated.scope_id,
              agent_id: agent_id,
              type: "memory_updated",
              importance: 0.6,
              payload: %{
                memory_id: memory_id,
                action: action,
                previous: previous
              }
            })

            # Broadcast for cache invalidation
            broadcast_memory_updated(updated.scope, updated.scope_id, memory_id)

            {:ok, Jason.encode!(%{id: memory_id, action: action, status: "success"})}

          {:error, changeset} when is_struct(changeset) ->
            {:error, "Update failed: #{inspect(changeset.errors)}"}

          {:error, reason} ->
            {:error, to_string(reason)}
        end
    end
  end

  defp broadcast_memory_updated(scope, scope_id, memory_id) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "memory:#{scope}:#{scope_id}",
      {:memory_updated, memory_id}
    )

    Synapsis.Memory.Cache.invalidate(scope, scope_id)
  end
end
