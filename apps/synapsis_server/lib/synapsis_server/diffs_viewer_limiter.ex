defmodule SynapsisServer.DiffsViewerLimiter do
  @moduledoc """
  Bounded, node-local failed-viewer counters for explicitly enabled remote Diffs.

  Mirrors the pinned viewer's 40 failures per minute, one-minute lockout and
  2048 identities. Active locks survive capacity pressure; an overflow lock
  protects new identities when every retained entry is locked. Successful
  remote reads reset their identity. Loopback serving does not use this owner.
  """
  use GenServer

  @window 60_000
  @max_failures 40
  @max_entries 2_048

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def check(key), do: call({:check, key})
  def record_failure(key), do: call({:failure, key})
  def reset(key), do: call({:reset, key})

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, sequence: 0, overflow_until: nil}}

  @impl true
  def handle_call({:check, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(state.entries, key) do
      {:ok, previous} ->
        entry = refresh(previous, now)

        entry =
          if is_nil(entry.locked_until) and length(entry.attempts) >= @max_failures,
            do: %{entry | locked_until: now + @window},
            else: entry

        answer = if locked?(entry, now), do: {:error, entry.locked_until - now}, else: :ok
        {:reply, answer, %{state | entries: Map.put(state.entries, key, entry)}}

      :error ->
        state = overflow(state, now)

        answer =
          if is_integer(state.overflow_until), do: {:error, state.overflow_until - now}, else: :ok

        {:reply, answer, state}
    end
  end

  def handle_call({:failure, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        {:reply, :ok, %{state | entries: Map.put(state.entries, key, fail(entry, now))}}

      :error ->
        state = make_room(state, now)

        if map_size(state.entries) < @max_entries do
          entry = fail(%{attempts: [], locked_until: nil, sequence: state.sequence}, now)

          {:reply, :ok,
           %{state | entries: Map.put(state.entries, key, entry), sequence: state.sequence + 1}}
        else
          until = max(state.overflow_until || now, now + @window)
          {:reply, :ok, %{state | overflow_until: until}}
        end
    end
  end

  def handle_call({:reset, key}, _from, state),
    do: {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}

  defp call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp fail(entry, now) do
    if locked?(entry, now) do
      entry
    else
      entry = refresh(entry, now)
      attempts = [now | entry.attempts]

      %{
        entry
        | attempts: attempts,
          locked_until: if(length(attempts) >= @max_failures, do: now + @window)
      }
    end
  end

  defp refresh(%{locked_until: until} = entry, now) when is_integer(until) and now >= until,
    do: %{entry | attempts: [], locked_until: nil}

  defp refresh(entry, now),
    do: %{entry | attempts: Enum.filter(entry.attempts, &(&1 > now - @window))}

  defp locked?(%{locked_until: until}, now), do: is_integer(until) and now < until

  defp prune(state, now) do
    entries =
      Enum.reduce(state.entries, %{}, fn {key, entry}, acc ->
        entry = refresh(entry, now)
        if locked?(entry, now) or entry.attempts != [], do: Map.put(acc, key, entry), else: acc
      end)

    %{state | entries: entries}
  end

  defp make_room(state, now) when map_size(state.entries) >= @max_entries do
    state = prune(state, now)

    if map_size(state.entries) < @max_entries do
      state
    else
      oldest =
        state.entries
        |> Enum.reject(fn {_, entry} -> locked?(entry, now) end)
        |> Enum.min_by(fn {_, entry} -> entry.sequence end, fn -> nil end)

      case oldest do
        {key, _} -> %{state | entries: Map.delete(state.entries, key)}
        nil -> state
      end
    end
  end

  defp make_room(state, _now), do: state

  defp overflow(%{overflow_until: until} = state, now) when is_integer(until) do
    state = if map_size(state.entries) >= @max_entries, do: prune(state, now), else: state

    if now >= until or map_size(state.entries) < @max_entries,
      do: %{state | overflow_until: nil},
      else: state
  end

  defp overflow(state, _now), do: state
end
