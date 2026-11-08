defmodule Synapsis.Web.Search.Cache do
  @moduledoc "Bounded process-local search results shared across native invocations. HTTP runs in callers."
  use GenServer

  @limit 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key, ttl \\ :infinity), do: GenServer.call(__MODULE__, {:get, key, ttl}, 5_000)
  def put(key, result, ttl), do: GenServer.call(__MODULE__, {:put, key, result, ttl}, 5_000)

  @impl true
  def init(_), do: {:ok, %{entries: %{}, sequence: 0}}

  @impl true
  def handle_call({:get, _key, 0}, _, state), do: {:reply, :miss, state}

  def handle_call({:get, key, ttl}, _, state) do
    timestamp = now()

    case state.entries[key] do
      %{expires_at: expires} when expires <= timestamp ->
        {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}

      %{inserted_at: inserted, value: value} ->
        result = if ttl == :infinity or timestamp - inserted < ttl, do: {:ok, value}, else: :miss
        {:reply, result, state}

      nil ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, _key, _result, 0}, _, state), do: {:reply, :ok, state}

  def handle_call({:put, key, result, ttl}, _, state) do
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
      expires_at: timestamp + ttl,
      inserted_at: timestamp,
      sequence: sequence,
      value: result
    }

    {:reply, :ok, %{state | entries: Map.put(entries, key, entry), sequence: state.sequence + 1}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
