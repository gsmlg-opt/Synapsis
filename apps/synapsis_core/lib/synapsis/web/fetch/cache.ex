defmodule Synapsis.Web.Fetch.Cache do
  @moduledoc "One hundred readable document entries with a fixed fifteen-minute TTL. HTTP runs in callers."
  use GenServer

  @limit 100
  @ttl_ms 900_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key, deadline), do: call({:get, key, deadline}, deadline)

  def put(key, value, deadline) when is_map(value) do
    if :erlang.external_size(value) <= 1_048_576,
      do: call({:put, key, value, deadline}, deadline),
      else: {:error, :value_too_large}
  end

  @impl true
  def init(_), do: {:ok, %{entries: %{}, sequence: 0}}

  @impl true
  def handle_call({:get, _, deadline}, _, state) when not is_integer(deadline),
    do: {:reply, {:error, :invalid_deadline}, state}

  def handle_call({:get, key, deadline}, _, state) do
    if now() < deadline,
      do: read(key, state),
      else: {:reply, {:error, :timeout}, state}
  end

  def handle_call({:put, key, value, deadline}, _, state) do
    if now() < deadline,
      do: write(key, value, state),
      else: {:reply, {:error, :timeout}, state}
  end

  defp read(key, state) do
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

  defp write(key, value, state) do
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

  defp call(request, deadline) do
    GenServer.call(__MODULE__, request, max(1, deadline - now()))
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
