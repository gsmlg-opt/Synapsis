defmodule Synapsis.Session.ReadSnapshot do
  @moduledoc """
  Invocation-local historical reads from the configured file-backed Concord store.

  Capture binds opaque metadata to one committed revision, its actual creation
  record and the existing local Turso pool. Pages retain that revision and the
  original deadline, including when a caller widens a previous selection.
  Validation checks session lifecycles at one later common revision; ordinary
  metadata edits and appends do not invalidate a lifecycle.

  These handles are private BEAM values, not persisted or JSON tokens. The pool
  fence supports the configured local file and ordinary reconnects to that file;
  it does not establish identity across external file replacement, in-memory
  databases or remote synchronization. Limits apply to already-decoded terms,
  not allocations or underlying native scan work. Native work in progress
  cannot be forcibly interrupted by the deadline checks.
  """

  alias Concord.KV
  alias Concord.KV.Record
  alias Synapsis.Session.Store

  @default_bytes 65_536
  @maximum_bytes 1_048_576
  @maximum_index 999_999_999_999
  @seek_limit 512
  @tail_key_page_size 100
  @enforce_keys [
    :owner,
    :session_id,
    :revision,
    :create_revision,
    :deadline,
    :meta,
    :meta_record,
    :max_bytes
  ]
  defstruct [
    :owner,
    :session_id,
    :revision,
    :create_revision,
    :deadline,
    :meta,
    :meta_record,
    :max_bytes,
    version: 1
  ]

  @opaque t :: %__MODULE__{
            version: 1,
            owner: {:concord_turso, pid()},
            session_id: binary(),
            revision: pos_integer(),
            create_revision: pos_integer(),
            deadline: integer(),
            meta: map(),
            meta_record: map(),
            max_bytes: pos_integer()
          }

  @doc "Capture metadata at one committed revision within an original five-second allowance."
  @spec capture(binary(), keyword()) :: {:ok, t()} | {:error, atom()}
  def capture(id, opts \\ []) do
    with true <- canonical_id?(id),
         {:ok, deadline, max_bytes} <- capture_options(opts),
         {:ok, owner} <- configured_owner(),
         context = %{owner: owner, deadline: deadline},
         {:ok, revision} <- read_revision(context),
         {:ok, record} <- metadata_record(context, id, revision),
         :ok <- present_metadata(record),
         {:ok, meta} <- read_map(context, Store.meta_key(id), revision),
         snapshot = %__MODULE__{
           owner: owner,
           session_id: id,
           revision: revision,
           create_revision: record.create_revision,
           deadline: deadline,
           meta: meta,
           meta_record: record,
           max_bytes: max_bytes
         },
         :ok <- within_bytes(:erlang.external_size(snapshot), max_bytes),
         {:ok, _remaining} <- check(context) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Read a bounded historical page, always returning complete turns in chronological order."
  @spec read_page(t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def read_page(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         {:ok, order, cursor, limit, max_bytes} <- page_options(opts),
         context = %{owner: snapshot.owner, deadline: snapshot.deadline},
         {:ok, _remaining} <- check(context),
         prefix = Store.turns_prefix(snapshot.session_id),
         range = page_range(snapshot.session_id, prefix, order, cursor),
         selection = %{prefix: prefix, order: order, limit: limit, max_bytes: max_bytes},
         {:ok, keys, more, record_bytes} <-
           collect_keys(context, snapshot.revision, range, selection, @seek_limit, [], 0),
         keys = Enum.sort_by(keys, &elem(&1, 1)),
         page = %{
           turns: [],
           has_more: more,
           next_cursor: next_cursor(keys, order, more),
           truncated: false
         },
         {:ok, page} <-
           read_turns(context, snapshot.revision, keys, page, record_bytes, max_bytes),
         {:ok, _remaining} <- check(context) do
      {:ok, page}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc """
  Count canonical historical turn keys and retain their newest sparse indices.

  `:retain` defaults to 100 and accepts 1..10000. Entries are chronological,
  with dense one-based ordinals in the complete captured history. No turn
  values or metadata counts are read. The original owner, revision and deadline
  apply to every key page, without a separate total-key scan ceiling.

  `:max_bytes` defaults to 65536 and accepts 1..1048576. It bounds the decoded
  current key page together with retained indices and, when built, the result;
  discarded key pages do not accumulate against this allowance. This does not
  bound native scan work or allocations before decoded terms are checked.
  """
  @spec tail_index(t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def tail_index(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         {:ok, retain, max_bytes} <- tail_index_options(opts),
         context = %{owner: snapshot.owner, deadline: snapshot.deadline},
         {:ok, _remaining} <- check(context),
         prefix = Store.turns_prefix(snapshot.session_id),
         range = page_range(snapshot.session_id, prefix, :desc, nil),
         selection = %{prefix: prefix, retain: retain, max_bytes: max_bytes},
         state = %{total: 0, retained: 0, indices: []},
         {:ok, state, page_bytes} <-
           collect_tail_index(context, snapshot.revision, range, selection, state),
         entries =
           Enum.with_index(state.indices, state.total - state.retained + 1)
           |> Enum.map(fn {index, ordinal} -> %{index: index, ordinal: ordinal} end),
         result = %{
           total_turns: state.total,
           entries: entries,
           has_older: state.total > state.retained
         },
         :ok <-
           within_bytes(
             page_bytes + :erlang.external_size(state.indices) + :erlang.external_size(result),
             max_bytes
           ),
         {:ok, _remaining} <- check(context) do
      {:ok, result}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Read the original stored pending list at the captured revision and owner."
  def read_pending(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         true <- closed_options?(opts, [:max_bytes]),
         max_bytes = Keyword.get(opts, :max_bytes, @default_bytes),
         true <- valid_bytes?(max_bytes),
         context = %{owner: snapshot.owner, deadline: snapshot.deadline},
         {:ok, result} <-
           storage_call(context, fn remaining ->
             KV.get(Store.value_key(snapshot.session_id, "pending_inputs"),
               engine: :turso,
               revision: snapshot.revision,
               timeout: remaining
             )
           end),
         {:ok, entries} <- pending_entries(result),
         result = %{entries: entries},
         :ok <- within_bytes(:erlang.external_size(result), max_bytes),
         {:ok, _remaining} <- check(context) do
      {:ok, result}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp pending_entries({:ok, entries}) when is_list(entries) do
    if Enum.all?(entries, &is_map/1), do: {:ok, entries}, else: {:error, :invalid_record}
  end

  defp pending_entries({:error, :not_found}), do: {:ok, []}
  defp pending_entries({:ok, _}), do: {:error, :invalid_record}
  defp pending_entries(other), do: storage_error(other)

  @doc "Count historical canonical keys while retaining only a bounded dense ordinal window."
  def ordinal_window(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         true <- closed_options?(opts, [:start, :limit, :max_bytes]),
         start = Keyword.get(opts, :start, 1),
         limit = Keyword.get(opts, :limit, 100),
         max_bytes = Keyword.get(opts, :max_bytes, @default_bytes),
         true <-
           is_integer(start) and start >= 1 and is_integer(limit) and limit >= 1 and
             valid_bytes?(max_bytes),
         context = %{owner: snapshot.owner, deadline: snapshot.deadline},
         prefix = Store.turns_prefix(snapshot.session_id),
         range = page_range(snapshot.session_id, prefix, :asc, nil),
         selection = %{prefix: prefix, start: start, limit: limit, max_bytes: max_bytes},
         {:ok, state} <-
           collect_ordinal_window(context, snapshot.revision, range, selection, %{
             total: 0,
             entries: []
           }),
         result = %{total_turns: state.total, entries: Enum.reverse(state.entries)},
         :ok <- within_bytes(:erlang.external_size(result), max_bytes),
         {:ok, _remaining} <- check(context) do
      {:ok, result}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp collect_ordinal_window(context, revision, {start_key, end_key} = range, selection, state) do
    with {:ok, result} <-
           storage_call(context, fn remaining ->
             KV.list(
               engine: :turso,
               revision: revision,
               range: range,
               order: :asc,
               limit: @tail_key_page_size,
               keys_only: true,
               queue: true,
               timeout: remaining
             )
           end) do
      case result do
        {:ok, [], %{has_more: false, last_key: nil}} ->
          {:ok, state}

        {:ok, [_ | _] = records, %{has_more: more, last_key: key}} when is_boolean(more) ->
          with true <-
                 valid_tail_records?(
                   Enum.reverse(records),
                   revision,
                   start_key,
                   end_key,
                   @tail_key_page_size
                 ) and List.last(records).key == key,
               :ok <-
                 within_bytes(
                   :erlang.external_size(result) + :erlang.external_size(state),
                   selection.max_bytes
                 ) do
            state =
              Enum.reduce(records, state, fn record, state ->
                case canonical_index(record.key, selection.prefix) do
                  nil ->
                    state

                  index ->
                    ordinal = state.total + 1

                    entries =
                      if ordinal >= selection.start and
                           ordinal < selection.start + selection.limit,
                         do: [%{index: index, ordinal: ordinal} | state.entries],
                         else: state.entries

                    %{total: ordinal, entries: entries}
                end
              end)

            with :ok <-
                   within_bytes(
                     :erlang.external_size(result) + :erlang.external_size(state),
                     selection.max_bytes
                   ),
                 {:ok, _remaining} <- check(context) do
              if more,
                do:
                  collect_ordinal_window(
                    context,
                    revision,
                    continue_range(range, key, :asc),
                    selection,
                    state
                  ),
                else: {:ok, state}
            end
          else
            false -> {:error, :invalid_record}
            error -> error
          end

        {:ok, _, _} ->
          {:error, :invalid_record}

        other ->
          storage_error(other)
      end
    end
  end

  @doc "Validate distinct session lifecycles in input order at one common committed revision."
  @spec validate_many([t()]) :: {:ok, map()} | {:error, atom()}
  def validate_many(snapshots) when is_list(snapshots) and length(snapshots) in 1..200 do
    with true <- Enum.all?(snapshots, &valid_snapshot?/1),
         true <- distinct_ids?(snapshots),
         {:ok, context} <- validation_context(snapshots),
         {:ok, revision} <- read_revision(context),
         :ok <- current_enough(revision, snapshots),
         {:ok, targets, record_bytes} <- validate_targets(snapshots, context, revision, [], 0),
         result = %{revision: revision, targets: targets},
         :ok <- within_bytes(record_bytes + :erlang.external_size(result), @maximum_bytes),
         {:ok, _remaining} <- check(context) do
      {:ok, result}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def validate_many(_), do: {:error, :invalid_input}

  defp capture_options(opts) do
    with true <- closed_options?(opts, [:deadline, :max_bytes]) do
      now = System.monotonic_time(:millisecond)
      deadline = Keyword.get(opts, :deadline, now + 5_000)
      max_bytes = Keyword.get(opts, :max_bytes, @default_bytes)

      if is_integer(deadline) and valid_bytes?(max_bytes),
        do: {:ok, min(deadline, now + 5_000), max_bytes},
        else: {:error, :invalid_input}
    else
      false -> {:error, :invalid_input}
    end
  end

  defp page_options(opts) do
    if closed_options?(opts, [:order, :cursor, :limit, :max_bytes]) do
      order = Keyword.get(opts, :order, :asc)
      cursor = Keyword.get(opts, :cursor)
      limit = Keyword.get(opts, :limit, 20)
      max_bytes = Keyword.get(opts, :max_bytes, @default_bytes)

      if order in [:asc, :desc] and
           (is_nil(cursor) or (is_integer(cursor) and cursor in 0..@maximum_index)) and
           is_integer(limit) and limit in 1..100 and valid_bytes?(max_bytes),
         do: {:ok, order, cursor, limit, max_bytes},
         else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp tail_index_options(opts) do
    if closed_options?(opts, [:retain, :max_bytes]) do
      retain = Keyword.get(opts, :retain, 100)
      max_bytes = Keyword.get(opts, :max_bytes, @default_bytes)

      if is_integer(retain) and retain in 1..10_000 and valid_bytes?(max_bytes),
        do: {:ok, retain, max_bytes},
        else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp closed_options?(opts, allowed) when is_list(opts) do
    Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
  end

  defp closed_options?(_, _), do: false
  defp valid_bytes?(bytes), do: is_integer(bytes) and bytes in 1..@maximum_bytes

  defp canonical_id?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp canonical_id?(_), do: false

  defp configured_owner do
    config = Application.get_env(:concord, :turso, [])
    database = Keyword.get(config, :database)
    owner = Process.whereis(Concord.Turso.DB)

    if Keyword.get(config, :enabled, false) and is_binary(database) and database != "" and
         database != ":memory:" and
         not String.starts_with?(database, ["file:", "libsql:", "http:", "https:"]) and
         is_nil(Keyword.get(config, :remote_url)) and is_pid(owner) and node(owner) == node(),
       do: {:ok, {:concord_turso, owner}},
       else: {:error, :storage_unavailable}
  end

  defp check(%{owner: {:concord_turso, owner}, deadline: deadline}) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Process.whereis(Concord.Turso.DB) != owner -> {:error, :owner_changed}
      remaining <= 0 -> {:error, :timeout}
      true -> {:ok, remaining}
    end
  end

  # Check the original owner/deadline even when the public operation fails or exits.
  defp storage_call(context, fun) do
    with {:ok, remaining} <- check(context) do
      result = invoke(fun, remaining)
      with {:ok, _remaining} <- check(context), do: {:ok, result}
    end
  end

  defp invoke(fun, remaining) do
    fun.(remaining)
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  defp read_revision(context) do
    with {:ok, result} <- storage_call(context, &KV.revision(engine: :turso, timeout: &1)) do
      case result do
        {:ok, revision} when is_integer(revision) and revision > 0 -> {:ok, revision}
        {:ok, _} -> {:error, :invalid_record}
        other -> storage_error(other)
      end
    end
  end

  defp metadata_record(context, id, revision) do
    key = Store.meta_key(id)

    with {:ok, record, false} <- list_key(context, revision, {key, key <> <<0>>}, :asc) do
      {:ok, record}
    else
      {:ok, _, _} -> {:error, :invalid_record}
      error -> error
    end
  end

  defp present_metadata(nil), do: {:error, :not_found}
  defp present_metadata(_record), do: :ok

  defp list_key(context, revision, {start_key, end_key} = range, order) do
    with {:ok, result} <-
           storage_call(context, fn remaining ->
             KV.list(
               engine: :turso,
               revision: revision,
               range: range,
               order: order,
               limit: 1,
               keys_only: true,
               queue: true,
               timeout: remaining
             )
           end) do
      case result do
        {:ok, [], %{has_more: false, last_key: nil}} ->
          {:ok, nil, false}

        {:ok, [record], %{has_more: more, last_key: key}} when is_boolean(more) ->
          if valid_record?(record, revision) and record.key == key and
               key >= start_key and key < end_key,
             do: {:ok, record, more},
             else: {:error, :invalid_record}

        {:ok, _, _} ->
          {:error, :invalid_record}

        other ->
          storage_error(other)
      end
    end
  end

  defp valid_record?(%Record{} = record, revision) do
    key = Map.get(record, :key)

    map_size(record) == map_size(%Record{}) + 1 and
      is_binary(key) and byte_size(key) in 1..4_096 and
      is_nil(record.value) and is_integer(record.create_revision) and record.create_revision > 0 and
      is_integer(record.mod_revision) and record.mod_revision >= record.create_revision and
      record.mod_revision <= revision and is_integer(record.version) and record.version > 0 and
      is_nil(record.expires_at) and is_nil(record.lease_id) and is_map(record.metadata) and
      (is_nil(record.content_type) or is_binary(record.content_type))
  end

  defp valid_record?(_, _), do: false

  defp read_map(context, key, revision) do
    with {:ok, result} <-
           storage_call(context, &KV.get(key, engine: :turso, revision: revision, timeout: &1)) do
      case result do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:ok, _} -> {:error, :invalid_record}
        {:error, :not_found} -> {:error, :stale_snapshot}
        other -> storage_error(other)
      end
    end
  end

  defp valid_snapshot?(%__MODULE__{} = snapshot) do
    map_size(snapshot) == 10 and snapshot.version == 1 and canonical_id?(snapshot.session_id) and
      match?({:concord_turso, owner} when is_pid(owner) and node(owner) == node(), snapshot.owner) and
      is_integer(snapshot.revision) and snapshot.revision > 0 and
      is_integer(snapshot.create_revision) and snapshot.create_revision > 0 and
      snapshot.create_revision <= snapshot.revision and is_integer(snapshot.deadline) and
      valid_bytes?(snapshot.max_bytes) and is_map(snapshot.meta) and
      valid_record?(snapshot.meta_record, snapshot.revision) and
      snapshot.meta_record.key == Store.meta_key(snapshot.session_id) and
      snapshot.meta_record.create_revision == snapshot.create_revision and
      :erlang.external_size(snapshot) <= snapshot.max_bytes
  end

  defp valid_snapshot?(_), do: false

  defp page_range(id, prefix, :asc, cursor) do
    start_key = if is_nil(cursor), do: prefix, else: Store.turn_key(id, cursor) <> <<0>>
    {start_key, prefix <> "999999999999" <> <<0>>}
  end

  defp page_range(id, prefix, :desc, cursor) do
    end_key =
      if is_nil(cursor), do: prefix <> "999999999999" <> <<0>>, else: Store.turn_key(id, cursor)

    {prefix, end_key}
  end

  defp collect_keys(_context, _revision, {start_key, end_key}, _selection, _budget, keys, bytes)
       when start_key >= end_key,
       do: {:ok, keys, false, bytes}

  defp collect_keys(_context, _revision, _range, _selection, 0, _keys, _bytes),
    do: {:error, :scan_limit}

  defp collect_keys(context, revision, range, selection, budget, keys, bytes) do
    with {:ok, record, more} <- list_key(context, revision, range, selection.order) do
      if is_nil(record) do
        {:ok, keys, false, bytes}
      else
        bytes = bytes + :erlang.external_size(record)
        index = canonical_index(record.key, selection.prefix)

        with :ok <- within_bytes(bytes, selection.max_bytes),
             {:ok, _remaining} <- check(context) do
          cond do
            not is_nil(index) and length(keys) == selection.limit ->
              {:ok, keys, true, bytes}

            true ->
              keys = if is_nil(index), do: keys, else: [{record.key, index} | keys]

              if more do
                next_range = continue_range(range, record.key, selection.order)
                collect_keys(context, revision, next_range, selection, budget - 1, keys, bytes)
              else
                {:ok, keys, false, bytes}
              end
          end
        end
      end
    end
  end

  defp collect_tail_index(context, revision, range, selection, state) do
    with {:ok, records, more, last_key, page_bytes} <-
           list_tail_keys(context, revision, range),
         :ok <-
           within_bytes(
             page_bytes + :erlang.external_size(state.indices),
             selection.max_bytes
           ),
         state = retain_tail_indices(records, selection, state),
         :ok <-
           within_bytes(
             page_bytes + :erlang.external_size(state.indices),
             selection.max_bytes
           ),
         {:ok, _remaining} <- check(context) do
      if more do
        collect_tail_index(
          context,
          revision,
          continue_range(range, last_key, :desc),
          selection,
          state
        )
      else
        {:ok, state, page_bytes}
      end
    end
  end

  defp list_tail_keys(context, revision, {start_key, end_key} = range) do
    with {:ok, result} <-
           storage_call(context, fn remaining ->
             KV.list(
               engine: :turso,
               revision: revision,
               range: range,
               order: :desc,
               limit: @tail_key_page_size,
               keys_only: true,
               queue: true,
               timeout: remaining
             )
           end) do
      case result do
        {:ok, [], %{has_more: false, last_key: nil}} ->
          {:ok, [], false, nil, :erlang.external_size(result)}

        {:ok, [_ | _] = records, %{has_more: more, last_key: key}} when is_boolean(more) ->
          if valid_tail_records?(records, revision, start_key, end_key, @tail_key_page_size) and
               List.last(records).key == key and (not more or key > start_key) do
            {:ok, records, more, key, :erlang.external_size(result)}
          else
            {:error, :invalid_record}
          end

        {:ok, _, _} ->
          {:error, :invalid_record}

        other ->
          storage_error(other)
      end
    end
  end

  defp valid_tail_records?([], _revision, _start_key, _previous_key, _remaining), do: true

  defp valid_tail_records?([record | records], revision, start_key, previous_key, remaining)
       when remaining > 0 do
    valid_record?(record, revision) and record.key >= start_key and record.key < previous_key and
      valid_tail_records?(records, revision, start_key, record.key, remaining - 1)
  end

  defp valid_tail_records?(_records, _revision, _start_key, _previous_key, _remaining), do: false

  defp retain_tail_indices(records, selection, state) do
    Enum.reduce(records, state, fn record, state ->
      case canonical_index(record.key, selection.prefix) do
        nil ->
          state

        index when state.retained < selection.retain ->
          %{
            total: state.total + 1,
            retained: state.retained + 1,
            indices: [index | state.indices]
          }

        _index ->
          %{state | total: state.total + 1}
      end
    end)
  end

  defp canonical_index(key, prefix) do
    prefix_size = byte_size(prefix)

    if byte_size(key) == prefix_size + 12 and binary_part(key, 0, prefix_size) == prefix do
      suffix = binary_part(key, prefix_size, 12)
      if ascii_digits?(suffix), do: String.to_integer(suffix)
    end
  end

  defp ascii_digits?(<<>>), do: true
  defp ascii_digits?(<<byte, rest::binary>>) when byte in ?0..?9, do: ascii_digits?(rest)
  defp ascii_digits?(_), do: false

  defp continue_range({_start_key, end_key}, key, :asc), do: {after_key(key), end_key}
  defp continue_range({start_key, _end_key}, key, :desc), do: {start_key, key}
  defp after_key(key) when byte_size(key) < 4_096, do: key <> <<0>>
  defp after_key(key), do: increment_key(key)

  # A maximum-length key cannot grow. Carry through trailing 255 bytes instead.
  # A turn-range key has a fixed ASCII prefix, so the carry always terminates.
  defp increment_key(key) do
    prefix = binary_part(key, 0, byte_size(key) - 1)

    case :binary.last(key) do
      255 -> increment_key(prefix)
      byte -> prefix <> <<byte + 1>>
    end
  end

  defp next_cursor(_keys, _order, false), do: nil
  defp next_cursor(keys, :asc, true), do: keys |> List.last() |> elem(1)
  defp next_cursor(keys, :desc, true), do: keys |> hd() |> elem(1)

  defp read_turns(context, _revision, [], page, bytes, max_bytes) do
    with :ok <- within_bytes(bytes + :erlang.external_size(page), max_bytes),
         {:ok, _remaining} <- check(context),
         do: {:ok, page}
  end

  defp read_turns(context, revision, [{key, index} | keys], page, bytes, max_bytes) do
    with {:ok, turn} <- read_map(context, key, revision),
         page = %{page | turns: page.turns ++ [%{index: index, turn: turn}]},
         :ok <- within_bytes(bytes + :erlang.external_size(page), max_bytes),
         {:ok, _remaining} <- check(context) do
      read_turns(context, revision, keys, page, bytes, max_bytes)
    end
  end

  defp distinct_ids?(snapshots) do
    ids = Enum.map(snapshots, & &1.session_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp validation_context([first | _] = snapshots) do
    if Enum.all?(snapshots, &(&1.owner == first.owner)) do
      context = %{
        owner: first.owner,
        deadline: snapshots |> Enum.map(& &1.deadline) |> Enum.min()
      }

      with {:ok, _remaining} <- check(context), do: {:ok, context}
    else
      {:error, :owner_changed}
    end
  end

  defp current_enough(revision, snapshots) do
    if Enum.all?(snapshots, &(&1.revision <= revision)),
      do: :ok,
      else: {:error, :stale_snapshot}
  end

  defp validate_targets([], _context, _revision, targets, bytes),
    do: {:ok, Enum.reverse(targets), bytes}

  defp validate_targets([snapshot | snapshots], context, revision, targets, bytes) do
    with {:ok, record} <- metadata_record(context, snapshot.session_id, revision) do
      bytes = bytes + if(is_nil(record), do: 0, else: :erlang.external_size(record))

      target = %{
        session_id: snapshot.session_id,
        same_lifecycle: not is_nil(record) and record.create_revision == snapshot.create_revision
      }

      with :ok <- within_bytes(bytes, @maximum_bytes),
           {:ok, _remaining} <- check(context) do
        validate_targets(snapshots, context, revision, [target | targets], bytes)
      end
    end
  end

  defp within_bytes(bytes, maximum) when bytes <= maximum, do: :ok
  defp within_bytes(_bytes, _maximum), do: {:error, :payload_too_large}
  defp storage_error({:error, :timeout}), do: {:error, :timeout}
  defp storage_error(_), do: {:error, :storage_unavailable}
end
