defmodule Synapsis.Memory do
  @moduledoc "Query/persistence boundary for the memory system."

  import Ecto.Query
  alias Synapsis.{MemoryEvent, MemoryCheckpoint, SemanticMemory, Repo}

  # ── Events ──────────────────────────────────────────────────────────

  @spec append_event(map()) :: {:ok, MemoryEvent.t()} | {:error, Ecto.Changeset.t()}
  def append_event(attrs) do
    %MemoryEvent{}
    |> MemoryEvent.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec list_events(keyword()) :: [MemoryEvent.t()]
  def list_events(filters \\ []) do
    MemoryEvent
    |> apply_event_filters(filters)
    |> order_by([e], desc: e.inserted_at)
    |> maybe_limit(filters)
    |> maybe_offset(filters)
    |> Repo.all()
  end

  @spec count_events(keyword()) :: non_neg_integer()
  def count_events(filters \\ []) do
    MemoryEvent
    |> apply_event_filters(filters)
    |> Repo.aggregate(:count)
  end

  defp apply_event_filters(query, []), do: query

  defp apply_event_filters(query, [{:scope, val} | rest]) do
    query |> where([e], e.scope == ^to_string(val)) |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [{:scope_id, val} | rest]) do
    query |> where([e], e.scope_id == ^val) |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [{:agent_id, val} | rest]) do
    query |> where([e], e.agent_id == ^val) |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [{:run_id, val} | rest]) do
    query |> where([e], e.run_id == ^val) |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [{:type, val} | rest]) do
    query |> where([e], e.type == ^to_string(val)) |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [{:payload_key, {key, val}} | rest])
       when is_binary(key) and is_binary(val) do
    query
    |> where([e], fragment("? ->> ? = ?", e.payload, ^key, ^val))
    |> apply_event_filters(rest)
  end

  defp apply_event_filters(query, [_ | rest]), do: apply_event_filters(query, rest)

  # ── Checkpoints ─────────────────────────────────────────────────────

  @spec write_checkpoint(map()) :: {:ok, MemoryCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def write_checkpoint(attrs) do
    %MemoryCheckpoint{}
    |> MemoryCheckpoint.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec latest_checkpoint(String.t()) :: MemoryCheckpoint.t() | nil
  def latest_checkpoint(session_id) do
    MemoryCheckpoint
    |> where([c], c.session_id == ^session_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec latest_checkpoint_by_run(String.t()) :: MemoryCheckpoint.t() | nil
  def latest_checkpoint_by_run(run_id) do
    MemoryCheckpoint
    |> where([c], c.run_id == ^run_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec list_checkpoints(keyword()) :: [MemoryCheckpoint.t()]
  def list_checkpoints(filters \\ []) do
    MemoryCheckpoint
    |> apply_checkpoint_filters(filters)
    |> order_by([c], desc: c.inserted_at)
    |> maybe_limit(filters)
    |> maybe_offset(filters)
    |> Repo.all()
  end

  defp apply_checkpoint_filters(query, []), do: query

  defp apply_checkpoint_filters(query, [{:session_id, val} | rest]) do
    query |> where([c], c.session_id == ^val) |> apply_checkpoint_filters(rest)
  end

  defp apply_checkpoint_filters(query, [{:run_id, val} | rest]) do
    query |> where([c], c.run_id == ^val) |> apply_checkpoint_filters(rest)
  end

  defp apply_checkpoint_filters(query, [{:workflow, val} | rest]) do
    query |> where([c], c.workflow == ^val) |> apply_checkpoint_filters(rest)
  end

  defp apply_checkpoint_filters(query, [_ | rest]), do: apply_checkpoint_filters(query, rest)

  # ── Semantic Memories ───────────────────────────────────────────────

  @spec store_semantic(map()) :: {:ok, SemanticMemory.t()} | {:error, Ecto.Changeset.t()}
  def store_semantic(attrs) do
    %SemanticMemory{}
    |> SemanticMemory.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @spec update_semantic(SemanticMemory.t(), map()) ::
          {:ok, SemanticMemory.t()} | {:error, Ecto.Changeset.t()}
  def update_semantic(%SemanticMemory{} = memory, attrs) do
    memory
    |> SemanticMemory.update_changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  @spec get_semantic(String.t()) :: {:ok, SemanticMemory.t()} | {:error, :not_found}
  def get_semantic(id) do
    case Repo.get(SemanticMemory, id) do
      nil -> {:error, :not_found}
      memory -> {:ok, memory}
    end
  end

  @spec archive_semantic(SemanticMemory.t()) ::
          {:ok, SemanticMemory.t()} | {:error, Ecto.Changeset.t()}
  def archive_semantic(%SemanticMemory{} = memory) do
    update_semantic(memory, %{archived_at: DateTime.utc_now()})
  end

  @spec restore_semantic(SemanticMemory.t()) ::
          {:ok, SemanticMemory.t()} | {:error, Ecto.Changeset.t()}
  def restore_semantic(%SemanticMemory{} = memory) do
    update_semantic(memory, %{archived_at: nil})
  end

  @spec list_semantic(keyword()) :: [SemanticMemory.t()]
  def list_semantic(filters \\ []) do
    SemanticMemory
    |> apply_semantic_filters(filters)
    |> order_by([m], desc: m.inserted_at)
    |> maybe_limit(filters)
    |> maybe_offset(filters)
    |> Repo.all()
  end

  @spec count_semantic(keyword()) :: non_neg_integer()
  def count_semantic(filters \\ []) do
    SemanticMemory
    |> apply_semantic_filters(filters)
    |> Repo.aggregate(:count)
  end

  @doc "Full-text keyword search on title + summary with scope filtering."
  @spec search_semantic(String.t(), keyword()) :: [SemanticMemory.t()]
  def search_semantic(query, filters \\ []) do
    tsquery = sanitize_tsquery(query)

    SemanticMemory
    |> where(
      [m],
      fragment(
        "to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '')) @@ to_tsquery('english', ?)",
        m.title,
        m.summary,
        ^tsquery
      )
    )
    |> apply_semantic_filters(filters)
    |> order_by([m], desc: m.importance, desc: m.inserted_at)
    |> maybe_limit(filters)
    |> Repo.all()
  end

  @doc "Update access_count and last_accessed_at for retrieved memories."
  @spec touch_accessed([String.t()]) :: {non_neg_integer(), nil}
  def touch_accessed([]), do: {0, nil}

  def touch_accessed(ids) do
    now = DateTime.utc_now()

    from(m in SemanticMemory, where: m.id in ^ids)
    |> Repo.update_all(inc: [access_count: 1], set: [last_accessed_at: now])
  end

  defp apply_semantic_filters(query, []), do: query

  defp apply_semantic_filters(query, [{:scope, val} | rest]) do
    query |> where([m], m.scope == ^to_string(val)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:scope_id, val} | rest]) do
    query |> where([m], m.scope_id == ^val) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:kind, val} | rest]) do
    query |> where([m], m.kind == ^to_string(val)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:kinds, vals} | rest]) when is_list(vals) do
    strs = Enum.map(vals, &to_string/1)
    query |> where([m], m.kind in ^strs) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:tags, vals} | rest]) when is_list(vals) do
    query |> where([m], fragment("? @> ?", m.tags, ^vals)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:source, val} | rest]) do
    query |> where([m], m.source == ^to_string(val)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:contributed_by, val} | rest]) do
    query |> where([m], m.contributed_by == ^val) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:active, true} | rest]) do
    query |> where([m], is_nil(m.archived_at)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:active, false} | rest]) do
    query |> where([m], not is_nil(m.archived_at)) |> apply_semantic_filters(rest)
  end

  defp apply_semantic_filters(query, [{:scopes, scope_pairs} | rest]) when is_list(scope_pairs) do
    # Build OR conditions for scope pairs using dynamic to avoid corrupting existing WHERE clauses
    scope_condition =
      Enum.reduce(scope_pairs, dynamic(false), fn {scope, scope_id}, acc ->
        scope_str = to_string(scope)
        dynamic([m], ^acc or (m.scope == ^scope_str and m.scope_id == ^scope_id))
      end)

    query = where(query, ^scope_condition)
    apply_semantic_filters(query, rest)
  end

  defp apply_semantic_filters(query, [_ | rest]), do: apply_semantic_filters(query, rest)

  # ── Helpers ─────────────────────────────────────────────────────────

  defp maybe_limit(query, filters) do
    case Keyword.get(filters, :limit) do
      nil -> query
      n when is_integer(n) -> limit(query, ^n)
    end
  end

  defp maybe_offset(query, filters) do
    case Keyword.get(filters, :offset) do
      nil -> query
      n when is_integer(n) -> offset(query, ^n)
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_tsquery(query) when is_binary(query) do
    query
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" & ")
  end
end
