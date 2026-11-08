defmodule Synapsis.RoutineRuns do
  @moduledoc """
  Bounded, source-attributed terminal automation history from durable AgentRuns.

  Current source-qualified config visibility and the recorded execution route must
  both match. Older runs without explicit source attribution cannot be assigned
  and are not returned; empty results do not establish historical emptiness.

  Each page is a fresh current observation, not a stable snapshot. The complete
  candidate set (at most 1,000 current runs) is read before sorting by finished_at
  descending, then canonical run UUID descending for ties. UUID key order is not
  time order. One absolute deadline of at most five seconds covers every read.
  """

  alias Synapsis.{AgentRun, RoutineConfigs}
  alias Synapsis.AgentRun.Store

  @coverage %{source_attribution: "explicit_only", legacy_history: "unknown"}
  @strings [
    id: 36,
    kind: 32,
    status: 32,
    source: 32,
    assistant_name: 256,
    session_id: 36,
    routine_id: 36,
    heartbeat_id: 36,
    model: 256,
    provider: 256,
    summary: 2_048,
    error: 1_024,
    failure_class: 256
  ]

  @doc "Read terminal runs with limit/cursor, or an optional exact canonical run_id."
  def page(requester, source, id, opts \\ []) do
    with {:ok, options} <- options(opts),
         {:ok, visible} <-
           RoutineConfigs.get_visible(requester, source, id, deadline: options.deadline),
         {:ok, cursor} <- decode_cursor(options.cursor, visible.requester, source, id),
         {:ok, candidates} <- candidates(options),
         runs =
           candidates
           |> Enum.filter(&visible_run?(&1, requester, source, id))
           |> Enum.sort_by(&sort_key/1, :desc),
         {:ok, remaining} <- after_cursor(runs, cursor),
         {page, rest} = Enum.split(remaining, options.limit),
         result = %{
           requester: visible.requester,
           automation: %{source: source, id: id},
           coverage: @coverage,
           runs: Enum.map(page, &project/1),
           count: length(page),
           has_more: rest != [],
           next_cursor: next_cursor(page, rest, visible.requester, source, id)
         },
         :ok <- active(options.deadline),
         {:ok, encoded} <- Jason.encode(result),
         :ok <- active(options.deadline) do
      if byte_size(encoded) <= 65_536, do: {:ok, result}, else: {:error, :output_too_large}
    else
      {:error, reason}
      when reason in [
             :invalid_input,
             :invalid_cursor,
             :stale_cursor,
             :not_found,
             :requester_unavailable,
             :invalid_config,
             :timeout,
             :scan_limit,
             :output_too_large
           ] ->
        {:error, reason}

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp options(opts) do
    valid =
      is_list(opts) and Keyword.keyword?(opts) and
        Keyword.keys(opts) -- [:limit, :cursor, :run_id, :deadline] == [] and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        is_integer(Keyword.get(opts, :limit, 20)) and Keyword.get(opts, :limit, 20) in 1..100 and
        is_integer(Keyword.get(opts, :deadline, 0)) and
        (not Keyword.has_key?(opts, :run_id) or uuid?(opts[:run_id])) and
        not (Keyword.has_key?(opts, :run_id) and Keyword.has_key?(opts, :cursor))

    if valid do
      ceiling = now() + 5_000

      {:ok,
       %{
         limit: Keyword.get(opts, :limit, 20),
         cursor: opts[:cursor],
         run_id: opts[:run_id],
         deadline: min(Keyword.get(opts, :deadline, ceiling), ceiling)
       }}
    else
      {:error, :invalid_input}
    end
  end

  defp candidates(%{run_id: nil, deadline: deadline}), do: Store.bounded_candidates(deadline)

  defp candidates(%{run_id: id, deadline: deadline}) do
    case Store.fetch_until(id, deadline) do
      {:ok, run} -> {:ok, [run]}
      :not_found -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp visible_run?(run, requester, source, id) do
    AgentRun.terminal?(run) and run.assistant_name == requester and uuid?(run.id) and
      automation_ref(run) == %{"source" => source, "id" => id} and not is_nil(finished(run))
  end

  defp automation_ref(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "automation_ref", Map.get(metadata, :automation_ref)) do
      ref when is_map(ref) ->
        %{
          "source" => Map.get(ref, "source", Map.get(ref, :source)),
          "id" => Map.get(ref, "id", Map.get(ref, :id))
        }

      _ ->
        nil
    end
  end

  defp automation_ref(_), do: nil

  defp finished(run) do
    case run.finished_at do
      %DateTime{} = at ->
        DateTime.to_unix(at, :microsecond)

      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, at, _} -> DateTime.to_unix(at, :microsecond)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sort_key(run), do: {finished(run), run.id}

  @doc false
  def completion_projection(%{metadata: metadata}) when is_map(metadata) do
    {completion, completion_shortened} = bounded(metadata["automation_completion_status"], 32)
    {delivery, delivery_shortened} = project_delivery(metadata["automation_delivery"])
    fields = %{}

    fields =
      if is_binary(completion),
        do: Map.put(fields, :automation_completion_status, completion),
        else: fields

    fields =
      if is_map(delivery), do: Map.put(fields, :automation_delivery, delivery), else: fields

    flags = %{}

    flags =
      if completion_shortened,
        do: Map.put(flags, :automation_completion_status, true),
        else: flags

    flags = if delivery_shortened, do: Map.put(flags, :automation_delivery, true), else: flags
    {fields, flags}
  end

  def completion_projection(_run), do: {%{}, %{}}

  defp project_delivery(delivery) when is_map(delivery) do
    {projected, shortened} =
      Enum.reduce(
        [
          {"mode", 32},
          {"status", 32},
          {"suppression_reason", 64},
          {"error", 1_024},
          {"source_session_id", 36},
          {"message_id", 36}
        ],
        {%{}, false},
        fn {key, limit}, {result, shortened} ->
          {text, truncated} = bounded(delivery[key], limit)
          result = if is_binary(text), do: Map.put(result, key, text), else: result
          {result, shortened or truncated}
        end
      )

    projected =
      Enum.reduce(~w(delivered attempted), projected, fn key, acc ->
        if is_boolean(delivery[key]), do: Map.put(acc, key, delivery[key]), else: acc
      end)

    projected =
      Enum.reduce([{"http_status", 100..599}, {"attempt_count", 0..4}], projected, fn {key, range},
                                                                                      acc ->
        if is_integer(delivery[key]) and delivery[key] in range,
          do: Map.put(acc, key, delivery[key]),
          else: acc
      end)

    Enum.reduce(~w(intended resolved), {projected, shortened}, fn key, {acc, shortened} ->
      case delivery[key] do
        trace when is_map(trace) ->
          {to, to_shortened} = bounded(trace["to"], 2_048)
          {source, source_shortened} = bounded(trace["source"], 32)
          trace_projection = %{}

          trace_projection =
            if is_binary(to), do: Map.put(trace_projection, "to", to), else: trace_projection

          trace_projection =
            if is_binary(source),
              do: Map.put(trace_projection, "source", source),
              else: trace_projection

          trace_projection =
            if is_boolean(trace["ok"]),
              do: Map.put(trace_projection, "ok", trace["ok"]),
              else: trace_projection

          {Map.put(acc, key, trace_projection), shortened or to_shortened or source_shortened}

        _ ->
          {acc, shortened}
      end
    end)
  end

  defp project_delivery(_delivery), do: {nil, false}

  defp project(run) do
    {fields, truncated} =
      Enum.reduce(@strings, {%{}, %{}}, fn {key, limit}, {fields, flags} ->
        {value, shortened} = bounded(Map.get(run, key), limit)
        {Map.put(fields, key, value), if(shortened, do: Map.put(flags, key, true), else: flags)}
      end)

    {completion, completion_truncated} = completion_projection(run)
    truncated = Map.merge(truncated, completion_truncated)

    fields
    |> Map.merge(completion)
    |> Map.merge(%{
      attempt: run.attempt,
      automation_ref: automation_ref(run),
      started_at: datetime(run.started_at),
      finished_at: datetime(run.finished_at),
      scheduled_for: datetime(run.scheduled_for),
      inserted_at: datetime(run.inserted_at),
      truncated: truncated
    })
  end

  defp bounded(nil, _), do: {nil, false}

  defp bounded(value, limit) when is_binary(value) do
    if byte_size(value) <= limit, do: {value, false}, else: {utf8_prefix(value, limit), true}
  end

  defp bounded(_, _), do: {nil, false}

  defp utf8_prefix(value, limit) do
    prefix = binary_part(value, 0, limit)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, limit - 1)
  end

  defp datetime(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> DateTime.to_iso8601(at)
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  defp decode_cursor(nil, _, _, _), do: {:ok, nil}

  defp decode_cursor(cursor, requester, source, id)
       when is_binary(cursor) and byte_size(cursor) in 1..4_096 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, requester_id, requester_name, ^source, ^id, finished, run_id]} <-
           Jason.decode(json),
         true <- requester_id == requester.id and requester_name == requester.name,
         true <- is_integer(finished) and uuid?(run_id),
         anchor = {finished, run_id},
         true <- encode_cursor(requester, source, id, anchor) == cursor do
      {:ok, anchor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_, _, _, _), do: {:error, :invalid_cursor}
  defp after_cursor(runs, nil), do: {:ok, runs}

  defp after_cursor(runs, anchor) do
    case Enum.drop_while(runs, &(sort_key(&1) != anchor)) do
      [_ | rest] -> {:ok, rest}
      [] -> {:error, :stale_cursor}
    end
  end

  defp next_cursor(_, [], _, _, _), do: nil

  defp next_cursor(page, _, requester, source, id),
    do: encode_cursor(requester, source, id, sort_key(List.last(page)))

  defp encode_cursor(requester, source, id, {finished, run_id}),
    do:
      [1, requester.id, requester.name, source, id, finished, run_id]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false
  defp active(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
