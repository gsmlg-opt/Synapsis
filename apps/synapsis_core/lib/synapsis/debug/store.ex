defmodule Synapsis.Debug.Store do
  @moduledoc """
  ETS-backed store for debug entries scoped per session.
  Entries survive page refresh (channel rejoin reads from ETS) but vanish
  on server restart. No database persistence — debug payloads are large
  and ephemeral.

  All mutations are serialized through the GenServer to avoid race conditions
  on eviction. Reads go directly to ETS for concurrency.
  """
  use GenServer

  @table :debug_entries
  @max_entries_per_session 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns true if the Debug.Store process is running."
  @spec available?() :: boolean()
  def available?, do: Process.whereis(__MODULE__) != nil

  @impl true
  def init(_) do
    table =
      :ets.new(@table, [
        :named_table,
        :ordered_set,
        :protected,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec put_request(String.t(), map()) :: true
  def put_request(session_id, sanitized_request) do
    GenServer.call(__MODULE__, {:put_request, session_id, sanitized_request})
  end

  @spec put_response(String.t(), map()) :: true
  def put_response(session_id, sanitized_response) do
    GenServer.call(__MODULE__, {:put_response, session_id, sanitized_response})
  end

  @spec list_entries(String.t()) :: [map()]
  def list_entries(session_id) do
    GenServer.call(__MODULE__, {:list_entries, session_id})
  end

  @spec clear_entries(String.t()) :: non_neg_integer()
  def clear_entries(session_id) do
    GenServer.call(__MODULE__, {:clear_entries, session_id})
  end

  # -- GenServer callbacks (serialized mutations) --

  @impl true
  def handle_call({:put_request, session_id, sanitized_request}, _from, state) do
    entry =
      Map.merge(sanitized_request, %{
        request_timestamp: sanitized_request.timestamp,
        status: nil,
        response_headers: nil,
        response_body: nil,
        complete: nil,
        error: nil,
        duration_ms: nil,
        response_timestamp: nil
      })

    :ets.insert(@table, {{session_id, sanitized_request.request_id}, entry})
    do_evict(session_id)
    {:reply, true, state}
  end

  def handle_call({:put_response, session_id, sanitized_response}, _from, state) do
    key = {session_id, sanitized_response.request_id}

    case :ets.lookup(@table, key) do
      [{^key, existing}] ->
        merged =
          Map.merge(existing, %{
            status: sanitized_response.status,
            response_headers: sanitized_response.headers,
            response_body: sanitized_response.body,
            complete: sanitized_response.complete,
            error: sanitized_response.error,
            duration_ms: sanitized_response.duration_ms,
            response_timestamp: sanitized_response.timestamp
          })

        :ets.insert(@table, {key, merged})

      [] ->
        :ets.insert(@table, {key, sanitized_response})
    end

    {:reply, true, state}
  end

  def handle_call({:list_entries, session_id}, _from, state) do
    match_spec = [{{{session_id, :_}, :"$1"}, [], [:"$1"]}]

    entries =
      :ets.select(@table, match_spec)
      |> Enum.sort_by(&(&1[:request_timestamp] || &1[:timestamp]))

    {:reply, entries, state}
  end

  def handle_call({:clear_entries, session_id}, _from, state) do
    match_spec = [{{{session_id, :_}, :_}, [], [true]}]
    count = :ets.select_delete(@table, match_spec)
    {:reply, count, state}
  end

  defp do_evict(session_id) do
    entries = :ets.select(@table, [{{{session_id, :_}, :_}, [], [:"$_"]}])

    if length(entries) > @max_entries_per_session do
      entries
      |> Enum.sort_by(fn {_key, entry} -> entry[:request_timestamp] || entry[:timestamp] end)
      |> Enum.take(length(entries) - @max_entries_per_session)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end
end
