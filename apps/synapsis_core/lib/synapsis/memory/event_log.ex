defmodule Synapsis.Memory.EventLog do
  @moduledoc """
  Node-local, in-memory log of memory events (task/run/tool lifecycle).

  ADR-006 C4: memory events are ephemeral observability data, not durable
  semantic memory, so they live in a `:public` ETS table (ordered by insertion)
  rather than the file/Concord stores. Events are scoped by `scope`/`scope_id`.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Append an event. Returns `{:ok, record}` (atom-keyed, id/inserted_at filled)."
  def append(attrs) when is_map(attrs) do
    ensure_table()

    record =
      attrs
      |> atomize()
      |> Map.put_new(:id, Ecto.UUID.generate())
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    :ets.insert(@table, {System.unique_integer([:monotonic, :positive]), record})
    {:ok, record}
  end

  @doc "List events (insertion order), optionally filtered by scope/scope_id and limit."
  def list(filters \\ []) do
    scope = Keyword.get(filters, :scope)
    scope_id = Keyword.get(filters, :scope_id)
    limit = Keyword.get(filters, :limit)

    events =
      case :ets.info(@table) do
        :undefined -> []
        _ -> @table |> :ets.tab2list() |> Enum.map(fn {_seq, record} -> record end)
      end
      |> Enum.filter(&scope_match?(&1, scope, scope_id))

    if is_integer(limit), do: Enum.take(events, limit), else: events
  end

  @doc "Count events matching the filters."
  def count(filters \\ []), do: filters |> list() |> length()

  # ── internals ──────────────────────────────────────────────────────────────

  defp scope_match?(_record, nil, _scope_id), do: true

  defp scope_match?(record, scope, scope_id) do
    record[:scope] == to_string(scope) and
      (is_nil(scope_id) or record[:scope_id] == scope_id)
  end

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_atom(k), v}
    end)
  end

  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
