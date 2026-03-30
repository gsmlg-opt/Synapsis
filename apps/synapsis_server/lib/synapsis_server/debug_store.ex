defmodule SynapsisServer.DebugStore do
  @moduledoc """
  ETS-backed store for debug entries scoped per session.
  Entries survive page refresh (channel rejoin reads from ETS) but vanish
  on server restart. No database persistence — debug payloads are large
  and ephemeral.
  """
  use GenServer

  @table :debug_entries
  @max_entries_per_session 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table =
      :ets.new(@table, [
        :named_table,
        :ordered_set,
        :public,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec put_request(String.t(), map()) :: true
  def put_request(session_id, sanitized_request) do
    entry =
      Map.merge(sanitize_for_json(sanitized_request), %{
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
    maybe_evict(session_id)
    true
  end

  @spec put_response(String.t(), map()) :: true
  def put_response(session_id, sanitized_response) do
    key = {session_id, sanitized_response.request_id}

    case :ets.lookup(@table, key) do
      [{^key, existing}] ->
        safe = sanitize_for_json(sanitized_response)

        merged =
          Map.merge(existing, %{
            status: safe.status,
            response_headers: safe[:headers],
            response_body: safe[:body],
            complete: safe.complete,
            error: safe[:error],
            duration_ms: safe.duration_ms,
            response_timestamp: safe[:timestamp]
          })

        :ets.insert(@table, {key, merged})

      [] ->
        :ets.insert(@table, {key, sanitized_response})
    end

    true
  end

  @spec list_entries(String.t()) :: [map()]
  def list_entries(session_id) do
    match_spec = [{{{session_id, :_}, :"$1"}, [], [:"$1"]}]
    :ets.select(@table, match_spec)
  end

  @spec clear_entries(String.t()) :: non_neg_integer()
  def clear_entries(session_id) do
    match_spec = [{{{session_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  # Convert all values to JSON-safe types (tuples → maps, atoms → strings, DateTimes → ISO8601)
  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = v} -> {k, DateTime.to_iso8601(v)}
      {k, v} when is_boolean(v) -> {k, v}
      {k, nil} -> {k, nil}
      {k, v} when is_atom(v) -> {k, to_string(v)}
      {k, v} when is_list(v) -> {k, sanitize_list(v)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_list(list) do
    Enum.map(list, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        %{"name" => key, "value" => value}

      other ->
        other
    end)
  end

  defp maybe_evict(session_id) do
    entries = :ets.select(@table, [{{{session_id, :_}, :_}, [], [:"$_"]}])

    if length(entries) > @max_entries_per_session do
      entries
      |> Enum.sort_by(fn {_key, entry} -> entry[:request_timestamp] || entry[:timestamp] end)
      |> Enum.take(length(entries) - @max_entries_per_session)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end
end
