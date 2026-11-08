defmodule Synapsis.Web.XSearch.Cache do
  @moduledoc "One hundred X-search entries with per-entry expiry and caller TTL limits. HTTP runs in callers."
  use GenServer

  @limit 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key, ttl), do: GenServer.call(__MODULE__, {:get, key, ttl}, 5_000)
  def put(key, value, ttl), do: GenServer.call(__MODULE__, {:put, key, value, ttl}, 5_000)

  @impl true
  def init(_), do: {:ok, %{entries: %{}, sequence: 0}}

  @impl true
  def handle_call({:get, _key, ttl}, _, state) when ttl <= 0, do: {:reply, :miss, state}

  def handle_call({:get, key, ttl}, _, state) do
    timestamp = now()

    case state.entries[key] do
      %{expires_at: expires} when timestamp >= expires ->
        {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}

      %{inserted_at: inserted, value: value} ->
        {:reply, if(timestamp - inserted < ttl, do: {:ok, value}, else: :miss), state}

      nil ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, _key, _value, ttl}, _, state)
      when not is_integer(ttl) or ttl <= 0 or ttl > 9_007_199_254_740_991,
      do: {:reply, :ok, state}

  def handle_call({:put, key, value, ttl}, _, state) do
    entries =
      if map_size(state.entries) >= @limit do
        {oldest, _} = Enum.min_by(state.entries, fn {_, entry} -> entry.sequence end)
        Map.delete(state.entries, oldest)
      else
        state.entries
      end

    timestamp = now()
    sequence = if entries[key], do: entries[key].sequence, else: state.sequence

    entry = %{
      value: value,
      inserted_at: timestamp,
      expires_at: timestamp + ttl,
      sequence: sequence
    }

    {:reply, :ok, %{state | entries: Map.put(entries, key, entry), sequence: state.sequence + 1}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
