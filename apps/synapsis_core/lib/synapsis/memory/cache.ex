defmodule Synapsis.Memory.Cache do
  @moduledoc """
  ETS-backed hot cache for memory retrieval results.
  Invalidated via PubSub on memory_promoted/memory_updated/memory_archived events.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 30_000
  @pubsub Synapsis.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    Phoenix.PubSub.subscribe(@pubsub, "memory:cache_invalidation")
    {:ok, %{}}
  end

  @doc "Get cached retrieval results."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc "Cache a retrieval result."
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms \\ @ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc "Invalidate all entries matching a scope."
  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(scope, scope_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "memory:cache_invalidation",
      {:invalidate_scope, scope, scope_id}
    )
  end

  @doc "Clear entire cache."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def handle_info({:invalidate_scope, _scope, _scope_id}, state) do
    # Simple approach: clear entire cache on any invalidation
    # More granular invalidation can be added later if needed
    :ets.delete_all_objects(@table)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
