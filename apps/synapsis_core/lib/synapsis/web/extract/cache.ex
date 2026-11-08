defmodule Synapsis.Web.Extract.Cache do
  @moduledoc "One hundred extraction entries with a fixed fifteen-minute TTL. HTTP runs in callers."
  use GenServer

  @limit 100
  @ttl_ms 900_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key}, 5_000)
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value}, 5_000)

  @impl true
  def init(_), do: {:ok, %{entries: %{}, sequence: 0}}

  @impl true
  def handle_call({:get, key}, _, state) do
    case state.entries[key] do
      %{expires_at: expires, value: value} ->
        if now() < expires do
          {:reply, {:ok, value}, state}
        else
          {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}
        end

      nil ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, key, value}, _, state) do
    entries =
      if map_size(state.entries) >= @limit do
        {oldest, _} = Enum.min_by(state.entries, fn {_, entry} -> entry.sequence end)
        Map.delete(state.entries, oldest)
      else
        state.entries
      end

    sequence = if entries[key], do: entries[key].sequence, else: state.sequence
    entry = %{value: value, expires_at: now() + @ttl_ms, sequence: sequence}
    {:reply, :ok, %{state | entries: Map.put(entries, key, entry), sequence: state.sequence + 1}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
