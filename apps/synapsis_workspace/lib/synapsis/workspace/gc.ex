defmodule Synapsis.Workspace.GC do
  @moduledoc """
  Periodic garbage collector for workspace documents (WS-9).

  Runs on a configurable interval and performs four cleanup tasks:

    1. **Session scratch cleanup** — hard-deletes `session_scratch` documents
       whose session completed (updated_at) more than `session_scratch_retention_days` ago.

    2. **Draft version pruning** — removes old version snapshots for `draft`
       documents beyond the `draft_version_retention` count.

    3. **Orphaned blob cleanup** — deletes blob files that are no longer
       referenced by any document or document version.

    4. **Expired soft-delete cleanup** — hard-deletes documents that were
       soft-deleted more than `soft_delete_retention_days` ago.

  ## Configuration

      config :synapsis_workspace, :gc,
        session_scratch_retention_days: 7,
        draft_version_retention: 5,
        gc_interval_hours: 24,
        soft_delete_retention_days: 30
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Synapsis.Repo
  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocumentVersion

  @default_session_scratch_retention_days 7
  @default_draft_version_retention 5
  @default_gc_interval_hours 24
  @default_soft_delete_retention_days 30

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the GC GenServer. Pass `name:` to override registration."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Manually trigger a full GC cycle. Useful in tests and admin tooling.

  Returns a map with counts of affected records/blobs for each task.
  """
  @spec run_gc() :: map()
  def run_gc do
    GenServer.call(__MODULE__, :run_gc, :timer.minutes(5))
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_next_run()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:run_gc, _from, state) do
    result = do_gc()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:run_gc, state) do
    do_gc()
    schedule_next_run()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # GC orchestration
  # ---------------------------------------------------------------------------

  defp do_gc do
    if repo_available?() do
      started_at = System.monotonic_time(:millisecond)

      scratch_count = cleanup_session_scratch()
      version_count = prune_draft_versions()
      blob_count = cleanup_orphaned_blobs()
      expired_count = hard_delete_expired()

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      Logger.info("workspace_gc_complete",
        scratch_deleted: scratch_count,
        draft_versions_pruned: version_count,
        orphaned_blobs_deleted: blob_count,
        expired_docs_deleted: expired_count,
        elapsed_ms: elapsed_ms
      )

      %{
        scratch_deleted: scratch_count,
        draft_versions_pruned: version_count,
        orphaned_blobs_deleted: blob_count,
        expired_docs_deleted: expired_count
      }
    else
      Logger.info("workspace_gc_skipped", reason: "repo_unavailable")
      %{scratch_deleted: 0, draft_versions_pruned: 0, orphaned_blobs_deleted: 0, expired_docs_deleted: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # Task 1: Delete session scratch documents for completed sessions
  # ---------------------------------------------------------------------------

  @doc """
  Hard-deletes `session_scratch` documents whose associated session's
  `updated_at` is older than `session_scratch_retention_days`.

  We treat a session as "completed" when it has not been updated within the
  retention window (i.e. it is idle/finished).
  """
  def cleanup_session_scratch do
    retention_days = gc_config(:session_scratch_retention_days, @default_session_scratch_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    # Find IDs of documents of kind :session_scratch whose session updated_at is past cutoff.
    # Documents with no session_id are also cleaned up based on the document's own updated_at.
    stale_with_session =
      from d in WorkspaceDocument,
        join: s in Synapsis.Session,
        on: d.session_id == s.id,
        where: d.kind == :session_scratch and s.updated_at < ^cutoff,
        select: d.id

    stale_without_session =
      from d in WorkspaceDocument,
        where: d.kind == :session_scratch and is_nil(d.session_id) and d.updated_at < ^cutoff,
        select: d.id

    ids = Repo.all(stale_with_session) ++ Repo.all(stale_without_session)

    if ids == [] do
      0
    else
      # Delete versions first (FK constraint)
      {_, _} =
        from(v in WorkspaceDocumentVersion, where: v.document_id in ^ids)
        |> Repo.delete_all()

      {count, _} =
        from(d in WorkspaceDocument, where: d.id in ^ids)
        |> Repo.delete_all()

      count
    end
  end

  # ---------------------------------------------------------------------------
  # Task 2: Prune draft version history beyond retention count
  # ---------------------------------------------------------------------------

  @doc """
  For every document in the `:draft` lifecycle, keeps only the
  `draft_version_retention` most-recent versions and deletes the rest.
  """
  def prune_draft_versions do
    keep = gc_config(:draft_version_retention, @default_draft_version_retention)

    # Collect IDs of all draft documents that have version history.
    draft_doc_ids =
      from(d in WorkspaceDocument,
        where: d.lifecycle == :draft and is_nil(d.deleted_at),
        select: d.id
      )
      |> Repo.all()

    Enum.reduce(draft_doc_ids, 0, fn doc_id, acc ->
      {pruned, _} = prune_versions_for_doc(doc_id, keep)
      acc + pruned
    end)
  end

  defp prune_versions_for_doc(document_id, keep) do
    versions_to_keep =
      from v in WorkspaceDocumentVersion,
        where: v.document_id == ^document_id,
        order_by: [desc: v.version],
        limit: ^keep,
        select: v.id

    from(v in WorkspaceDocumentVersion,
      where: v.document_id == ^document_id and v.id not in subquery(versions_to_keep)
    )
    |> Repo.delete_all()
  end

  # ---------------------------------------------------------------------------
  # Task 3: Delete orphaned blobs
  # ---------------------------------------------------------------------------

  @doc """
  Finds blob refs stored on the filesystem (by walking the blob root directory)
  that are not referenced in any `workspace_documents.blob_ref` or
  `workspace_document_versions.blob_ref` column, then deletes them.

  Returns the number of orphaned blobs removed.
  """
  def cleanup_orphaned_blobs do
    blob_store = blob_store_module()
    blob_root = blob_store_root()

    case list_all_blob_refs(blob_root) do
      [] ->
        0

      all_refs ->
        referenced =
          MapSet.union(
            referenced_doc_blobs(),
            referenced_version_blobs()
          )

        orphaned = Enum.reject(all_refs, &MapSet.member?(referenced, &1))

        Enum.each(orphaned, fn ref ->
          blob_store.delete(ref)
        end)

        length(orphaned)
    end
  end

  # Walk the two-level shard directory: <aa>/<bb>/<rest> → aa <> bb <> rest
  defp list_all_blob_refs(root) do
    case File.ls(root) do
      {:error, _} ->
        []

      {:ok, aa_dirs} ->
        for aa <- aa_dirs,
            {:ok, bb_dirs} <- [File.ls(Path.join(root, aa))],
            bb <- bb_dirs,
            {:ok, files} <- [File.ls(Path.join([root, aa, bb]))],
            file <- files do
          aa <> bb <> file
        end
    end
  end

  defp referenced_doc_blobs do
    from(d in WorkspaceDocument,
      where: not is_nil(d.blob_ref),
      select: d.blob_ref
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp referenced_version_blobs do
    from(v in WorkspaceDocumentVersion,
      where: not is_nil(v.blob_ref),
      select: v.blob_ref
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Task 4: Hard-delete soft-deleted documents past retention
  # ---------------------------------------------------------------------------

  @doc """
  Hard-deletes documents that have been soft-deleted (deleted_at is set)
  for longer than `soft_delete_retention_days`.
  """
  def hard_delete_expired do
    retention_days = gc_config(:soft_delete_retention_days, @default_soft_delete_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    expired_ids =
      from(d in WorkspaceDocument,
        where: not is_nil(d.deleted_at) and d.deleted_at < ^cutoff,
        select: d.id
      )
      |> Repo.all()

    if expired_ids == [] do
      0
    else
      {_, _} =
        from(v in WorkspaceDocumentVersion, where: v.document_id in ^expired_ids)
        |> Repo.delete_all()

      {count, _} =
        from(d in WorkspaceDocument, where: d.id in ^expired_ids)
        |> Repo.delete_all()

      count
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp schedule_next_run do
    interval_hours = gc_config(:gc_interval_hours, @default_gc_interval_hours)
    interval_ms = interval_hours * 60 * 60 * 1000
    Process.send_after(self(), :run_gc, interval_ms)
  end

  defp gc_config(key, default) do
    :synapsis_workspace
    |> Application.get_env(:gc, [])
    |> Keyword.get(key, default)
  end

  defp blob_store_module do
    Application.get_env(
      :synapsis_workspace,
      :blob_store,
      Synapsis.Workspace.BlobStore.Local
    )
  end

  defp blob_store_root do
    Application.get_env(
      :synapsis_workspace,
      :blob_store_root,
      Path.expand("~/.config/synapsis/blobs")
    )
  end

  defp repo_available? do
    case Process.whereis(Synapsis.Repo) do
      nil -> false
      _pid -> true
    end
  end
end
