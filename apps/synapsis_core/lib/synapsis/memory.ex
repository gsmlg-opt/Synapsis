defmodule Synapsis.Memory do
  @moduledoc """
  Public facade for semantic memory.

  ADR-006 C4: memory is served by the pluggable memory port
  (`Synapsis.Memory.Adapter` → file or service adapter), not Postgres. The old
  `memory_events` / `memory_checkpoints` tables are removed; their functions are
  retained here as inert no-ops so existing callers keep working until they are
  migrated to telemetry / the session snapshot.
  """
  alias Synapsis.Memory.Adapter

  # ── semantic memory (delegates to the port) ─────────────────────────────────

  def store_semantic(attrs), do: Adapter.store(attrs)

  def update_semantic(memory_or_id, attrs), do: Adapter.update(id_of(memory_or_id), attrs)

  def get_semantic(id), do: Adapter.get(id_of(id))

  def archive_semantic(memory_or_id), do: Adapter.archive(id_of(memory_or_id))

  def restore_semantic(memory_or_id),
    do: Adapter.update(id_of(memory_or_id), %{archived: false, archived_at: nil})

  def list_semantic(filters \\ []), do: Adapter.list(filters)

  def count_semantic(filters \\ []), do: filters |> Adapter.list() |> length()

  def search_semantic(query, filters \\ []), do: Adapter.search(query, filters)

  def touch_accessed([]), do: :ok
  def touch_accessed(ids) when is_list(ids), do: Adapter.active().touch_accessed(ids)

  # ── events (node-local ETS log) / checkpoints (in Concord) ──────────────────

  @doc "Append a memory event (task/run/tool lifecycle) to the node-local event log."
  def append_event(attrs), do: Synapsis.Memory.EventLog.append(attrs)
  def list_events(filters \\ []), do: Synapsis.Memory.EventLog.list(filters)
  def count_events(filters \\ []), do: Synapsis.Memory.EventLog.count(filters)

  @doc "No-op: memory_checkpoints removed in C4 (session snapshot is in Concord)."
  def write_checkpoint(attrs), do: {:ok, attrs}
  def latest_checkpoint(_session_id), do: nil
  def latest_checkpoint_by_run(_run_id), do: nil
  def list_checkpoints(_filters \\ []), do: []

  # ── internals ───────────────────────────────────────────────────────────────

  defp id_of(%{id: id}), do: id
  defp id_of(%{"id" => id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(other), do: other
end
