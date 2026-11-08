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

  @doc "Search the calling agent's workspace Markdown without a global-store fallback."
  def search_workspace(root, query, opts \\ []),
    do: Synapsis.Memory.WorkspaceReader.search(root, query, opts)

  @doc "Read a workspace memory excerpt using a relative path and one-based lines."
  def read_workspace(root, path, opts \\ []),
    do: Synapsis.Memory.WorkspaceReader.read(root, path, opts)

  @doc "Recall host memory only while its persisted configuration explicitly enables it."
  def recall_host(query, opts \\ []) do
    if Keyword.keyword?(opts) do
      with {:ok, source} <- Synapsis.Memory.Settings.host_source(),
           true <- Keyword.get(opts, :source, source) === source do
        Synapsis.Memory.HostAgent.recall(source, query, Keyword.delete(opts, :source))
      else
        false -> {:error, :source_changed}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_input}
    end
  end

  @doc "Read one canonical host record only while its exact source remains enabled."
  def get_host(id, opts \\ []) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:source, :timeout, :deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      with {:ok, source} <- Synapsis.Memory.Settings.host_source(),
           true <- Keyword.get(opts, :source, source) === source do
        Synapsis.Memory.HostAgent.get(source, id, Keyword.delete(opts, :source))
      else
        false -> {:error, :source_changed}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_input}
    end
  end

  # ── semantic memory (delegates to the port) ─────────────────────────────────

  def store_semantic(attrs), do: Adapter.store(attrs)

  def update_semantic(memory_or_id, attrs), do: Adapter.update(id_of(memory_or_id), attrs)

  def get_semantic(id), do: Adapter.get(id_of(id))

  @doc "Read an exact file-backed record within a validated scope and scope ID."
  def get_semantic(id, filters) do
    if Adapter.active() == Synapsis.Memory.FileAdapter,
      do: Synapsis.Memory.FileAdapter.get(id_of(id), filters),
      else: {:error, :unsupported_adapter}
  end

  @doc "Update a file-backed record without widening its expected ownership."
  def update_semantic(memory_or_id, attrs, filters) do
    if Adapter.active() == Synapsis.Memory.FileAdapter,
      do: Synapsis.Memory.FileAdapter.update(id_of(memory_or_id), attrs, filters),
      else: {:error, :unsupported_adapter}
  end

  def archive_semantic(memory_or_id), do: Adapter.archive(id_of(memory_or_id))

  def archive_semantic(memory_or_id, filters) do
    if Adapter.active() == Synapsis.Memory.FileAdapter,
      do: Synapsis.Memory.FileAdapter.archive(id_of(memory_or_id), filters),
      else: {:error, :unsupported_adapter}
  end

  def restore_semantic(memory_or_id),
    do: Adapter.update(id_of(memory_or_id), %{archived: false, archived_at: nil})

  def restore_semantic(memory_or_id, filters),
    do: update_semantic(memory_or_id, %{archived: false, archived_at: nil}, filters)

  def list_semantic(filters \\ []), do: Adapter.list(filters)

  def count_semantic(filters \\ []), do: filters |> Adapter.list() |> length()

  def search_semantic(query, filters \\ []), do: Adapter.search(query, filters)

  @doc "Retrieve ranked semantic records from the current source without a shared cache."
  def retrieve_semantic(opts), do: Synapsis.Memory.Retriever.retrieve_uncached(opts)

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
