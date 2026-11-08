defmodule Synapsis.SessionDirectory do
  @moduledoc """
  Bounded durable session directory for a trusted operator.

  Default calls read only key pages and individual metadata, never turns or live
  processes. Scans pages of 100, at most 1,000 candidate keys; any further
  candidate returns `:scan_limit` instead of a partially sorted result. Orphan
  keys are skipped. The 1 MiB aggregate external-size budget applies to already
  read metadata, including full raw configs, not pre-decode allocations.

  Filters precede updated_at descending / id ascending ordering and offset
  pagination. Missing timestamps sort last. Activity means durable updated_at
  at the captured wall-clock time, not liveness. Calls observe independent
  current durable state, without cross-page snapshot or in-flight guarantees.
  One linked reader shares an absolute deadline of at most five seconds.
  Optional source-derived titles/previews use fixed-revision bounded pages for
  the first 100 selected rows. Captured metadata is the row materialization
  point; filters are reapplied without backfill or reordering. All selected
  lifecycles are validated together after helper completion, before pure result
  fitting. Public pretty JSON has a separate 64 KiB prefix/omission budget.
  """
  alias Synapsis.Session.{ReadSnapshot, Store}
  alias Synapsis.SessionDirectory.{History, Projection, Result}
  alias Synapsis.SessionDirectory.History.Services
  alias Synapsis.SessionDirectory.Projection.PortSession

  @metadata_limit 1_048_576
  @errors ~w(timeout scan_limit malformed_metadata payload_too_large storage_unavailable)a
  @text_fields ~w(title agent provider model status)a

  def list(input, context, opts \\ []) do
    with {:ok, %{page: page}} <- list_rendered(input, context, opts), do: {:ok, page}
  end

  def list_rendered(input, context, opts \\ []) do
    with :ok <- validate(input),
         :ok <- context_valid(context),
         {:ok, deadline} <- deadline(opts),
         captured_now = DateTime.utc_now(),
         {:ok, rows} <- bounded_read(deadline),
         :ok <- remaining(deadline),
         {entries, page} = select(rows, input, captured_now),
         {:ok, entries} <- materialize(entries, input, captured_now, opts, deadline),
         :ok <- remaining(deadline),
         {:ok, result} <- Result.fit_rendered(entries, page),
         :ok <- remaining(deadline) do
      {:ok, result}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed_metadata}
    end
  end

  def validate(input) when is_map(input) and not is_struct(input) do
    if Map.keys(input) --
         ~w(limit offset agent search active_minutes include_derived_titles include_last_message message_limit) ==
         [] and
         optional?(input, "limit", &(is_integer(&1) and &1 in 1..200)) and
         optional?(input, "offset", &(is_integer(&1) and &1 in 0..1000)) and
         optional?(input, "agent", &text?(&1, 255)) and
         optional?(input, "search", &text?(&1, 256)) and
         optional?(input, "active_minutes", &(is_integer(&1) and &1 in 1..525_600)) and
         optional?(input, "include_derived_titles", &is_boolean/1) and
         optional?(input, "include_last_message", &is_boolean/1) and
         optional?(input, "message_limit", &(is_integer(&1) and &1 >= 0)),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:agent_id, :session_id] and
         uuid?(context[:session_id]) and text?(context[:agent_id], 255),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp deadline(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :node_executable] == [] and
         (not Keyword.has_key?(opts, :node_executable) or is_binary(opts[:node_executable])) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = now() + 5_000
      value = Keyword.get(opts, :deadline, ceiling)
      if is_integer(value), do: {:ok, min(value, ceiling)}, else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp deadline(_), do: {:error, :invalid_input}

  defp bounded_read(deadline) do
    with :ok <- remaining(deadline) do
      task =
        Task.async(fn ->
          try do
            scan(nil, 0, 0, [], deadline)
          rescue
            _ -> {:error, :storage_unavailable}
          catch
            _, _ -> {:error, :storage_unavailable}
          end
        end)

      case Task.yield(task, max(deadline - now(), 0)) do
        {:ok, {:ok, rows}} ->
          {:ok, rows}

        {:ok, {:error, reason}} when reason in @errors ->
          {:error, reason}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        _ ->
          {:error, :storage_unavailable}
      end
    end
  end

  defp scan(cursor, count, bytes, rows, deadline) do
    options = [limit: 100, deadline: deadline]
    options = if cursor, do: Keyword.put(options, :cursor, cursor), else: options

    with :ok <- remaining(deadline),
         {:ok, page} <- Store.list_session_ids(options),
         {:ok, bytes, rows} <- read_metadata(page.session_ids, bytes, rows, deadline),
         :ok <- remaining(deadline) do
      count = count + length(page.session_ids)

      cond do
        page.has_more and count >= 1_000 -> {:error, :scan_limit}
        page.has_more -> scan(page.next_cursor, count, bytes, rows, deadline)
        true -> {:ok, rows}
      end
    end
  end

  defp read_metadata(ids, bytes, rows, deadline) do
    Enum.reduce_while(ids, {:ok, bytes, rows}, fn id, {:ok, bytes, rows} ->
      with :ok <- remaining(deadline),
           {:ok, meta} <- Store.get_meta(id, timeout: max(deadline - now(), 1)),
           :ok <- remaining(deadline),
           size = bytes + :erlang.external_size(meta),
           true <- size <= @metadata_limit,
           {:ok, row} <- project(meta, id) do
        {:cont, {:ok, size, [row | rows]}}
      else
        {:error, :not_found} -> {:cont, {:ok, bytes, rows}}
        false -> {:halt, {:error, :payload_too_large}}
        error -> {:halt, error}
      end
    end)
  end

  defp project(meta, id) when is_map(meta) and not is_struct(meta) do
    if field(meta, :id) === id and
         Enum.all?(@text_fields, &(is_nil(field(meta, &1)) or valid_string?(field(meta, &1)))) do
      with {:ok, inserted} <- timestamp(field(meta, :inserted_at)),
           {:ok, updated} <- timestamp(field(meta, :updated_at)) do
        row = Map.new(@text_fields, &{&1, field(meta, &1)})
        {:ok, Map.merge(row, %{id: id, inserted_at: inserted, updated_at: updated})}
      end
    else
      {:error, :malformed_metadata}
    end
  end

  defp project(_, _), do: {:error, :malformed_metadata}
  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(%DateTime{} = time) do
    timestamp(DateTime.to_iso8601(time))
  rescue
    _ -> {:error, :malformed_metadata}
  end

  defp timestamp(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, value, _} -> {:ok, DateTime.to_iso8601(value)}
      _ -> {:error, :malformed_metadata}
    end
  end

  defp timestamp(_), do: {:error, :malformed_metadata}

  defp select(rows, input, captured_now) do
    limit = Map.get(input, "limit", 100)
    offset = Map.get(input, "offset", 0)

    selected =
      rows
      |> Enum.filter(&matches?(&1, input, captured_now))
      |> Enum.sort_by(&{recency(&1.updated_at), &1.id})

    entries =
      selected
      |> Enum.slice(offset, limit)
      |> Enum.with_index(offset)
      |> Enum.map(fn {row, original_offset} ->
        %{row: row, offset: original_offset, enrich?: original_offset - offset < 100}
      end)

    more = length(selected) > offset + limit
    {entries, %{limit: limit, next_offset: if(more, do: offset + limit)}}
  end

  defp matches?(row, input, captured_now) do
    search = if input["search"], do: String.downcase(input["search"])

    cutoff =
      if input["active_minutes"], do: DateTime.add(captured_now, -60 * input["active_minutes"])

    (is_nil(input["agent"]) or row.agent == input["agent"]) and
      (is_nil(search) or
         Enum.any?([:id | @text_fields], fn key ->
           value = row[key]
           is_binary(value) and String.contains?(String.downcase(value), search)
         end)) and
      (is_nil(cutoff) or recent?(row.updated_at, cutoff))
  end

  defp materialize(entries, input, captured_now, opts, deadline) do
    message_limit = min(Map.get(input, "message_limit", 0), 20)

    if projection?(input) or message_limit > 0 do
      with {:ok, captured} <- capture(entries, input, captured_now, deadline),
           {:ok, enriched} <-
             enrich(captured, input, message_limit, opts[:node_executable], deadline),
           {:ok, retained} <- validate_lifecycles(enriched) do
        {:ok, retained}
      end
    else
      {:ok, entries}
    end
  end

  defp enrich([], _input, _message_limit, _node, _deadline), do: {:ok, []}

  defp enrich(entries, input, message_limit, node, deadline) do
    PortSession.run(node, deadline, fn broker ->
      with {:ok, entries, broker} <- project(entries, input, broker),
           {:ok, entries, _broker} <- history(entries, message_limit, broker) do
        {:ok, entries}
      end
    end)
  end

  defp project(entries, input, broker) do
    if projection?(input),
      do: Projection.project(entries, input, broker),
      else: {:ok, entries, broker}
  end

  defp history(entries, 0, broker), do: {:ok, entries, broker}

  defp history(entries, message_limit, broker),
    do: History.project(entries, message_limit, broker, Services.policy())

  defp projection?(input),
    do: input["include_derived_titles"] == true or input["include_last_message"] == true

  defp capture(entries, input, captured_now, deadline) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, handle} <-
             ReadSnapshot.capture(entry.row.id, deadline: deadline, max_bytes: @metadata_limit),
           {:ok, row} <- project(handle.meta, entry.row.id) do
        if matches?(row, input, captured_now),
          do: {:cont, {:ok, [Map.merge(entry, %{row: row, handle: handle}) | acc]}},
          else: {:cont, {:ok, acc}}
      else
        {:error, reason} when reason in [:not_found, :stale_snapshot] -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, captured} -> {:ok, Enum.reverse(captured)}
      error -> error
    end
  end

  defp validate_lifecycles([]), do: {:ok, []}

  defp validate_lifecycles(entries) do
    with {:ok, validation} <- ReadSnapshot.validate_many(Enum.map(entries, & &1.handle)) do
      current = Map.new(validation.targets, &{&1.session_id, &1.same_lifecycle})
      {:ok, Enum.filter(entries, &Map.fetch!(current, &1.row.id))}
    end
  end

  defp recency(nil), do: {1, 0}

  defp recency(value) do
    {:ok, time, _} = DateTime.from_iso8601(value)
    {0, -DateTime.to_unix(time, :microsecond)}
  end

  defp recent?(nil, _), do: false

  defp recent?(value, cutoff) do
    {:ok, time, _} = DateTime.from_iso8601(value)
    DateTime.compare(time, cutoff) != :lt
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp optional?(input, key, check), do: not Map.has_key?(input, key) or check.(input[key])
  defp valid_string?(value), do: is_binary(value) and String.valid?(value)

  defp text?(value, limit),
    do: valid_string?(value) and byte_size(value) in 1..limit and String.trim(value) != ""

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false
  defp remaining(deadline), do: if(deadline > now(), do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
