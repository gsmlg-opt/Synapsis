defmodule Synapsis.Session.Store do
  @moduledoc """
  Concord-backed persistence for agent sessions (ADR-006).

  Node-local key-value access over Concord's embedded Turso store. Keys are
  namespaced per session:

    * `sessions/<id>/meta`           — single session-metadata snapshot
    * `sessions/<id>/turns/<padded>` — one entry per conversation turn

  This module is a thin functional wrapper. Concord owns the process and the
  state, so there is no GenServer here (see the OTP "no process without a
  runtime reason" rule). A whole turn is committed atomically via a single
  `Concord.Turso.put_many/2`: the turn entry and the updated meta snapshot
  either both land or neither does.

  ## Concord notes (targets `concord 3.x`)

    * Synapsis disables Concord cluster mode and uses `Concord.Turso`
      explicitly for durable node-local KV.
    * Whole-turn writes use `Concord.Turso.put_many/2` so the turn entry and
      metadata snapshot are persisted through the same local engine call.
    * `Concord.Turso.prefix_scan/1` ordering is not part of this module's
      public contract. `list_turns/1` sorts ascending to honor the ADR-006
      "turns in order" contract.
  """

  alias Concord.Turso, as: KV

  @turn_pad 12
  @default_batch_size 500
  @list_page_size 10_000
  @presence_seek_budget 512
  @turn_page_seek_budget 512

  # ── key helpers ──────────────────────────────────────────────────────────

  @doc "Key for a session's metadata snapshot."
  def meta_key(id) when is_binary(id), do: "sessions/" <> id <> "/meta"

  @doc "Prefix covering every turn key for a session."
  def turns_prefix(id) when is_binary(id), do: "sessions/" <> id <> "/turns/"

  @doc "Key for turn `n` (zero-padded so lexicographic order matches numeric)."
  def turn_key(id, n) when is_binary(id) and is_integer(n) and n >= 0,
    do: turns_prefix(id) <> pad(n)

  @doc "Prefix covering every key for a session."
  def session_prefix(id) when is_binary(id), do: "sessions/" <> id <> "/"

  @doc "Key for an arbitrary session-scoped value (todos, permission, …)."
  def value_key(id, suffix) when is_binary(id) and is_binary(suffix),
    do: session_prefix(id) <> suffix

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(@turn_pad, "0")

  # ── session-scoped values (todos, permission, …) ──────────────────────────

  # Concord 3.1.10 supplies the public metadata read and revision CAS (gsmlg-dev/concord#107).
  @doc """
  Read an opaque session-scoped value and its revision from one observation.

  IDs and suffixes are valid UTF-8 segments of 1..4096 bytes, excluding slash,
  backslash, NUL, `.` and `..`. The only option is a unique atom-key `:timeout`
  in 1..5000 milliseconds (default 5000). Absence is returned only for native
  `:not_found`; storage errors never become defaults.
  """
  @spec value_snapshot(binary(), binary(), keyword()) ::
          :not_found | {:ok, %{value: term(), revision: pos_integer()}} | {:error, term()}
  def value_snapshot(id, suffix, opts \\ []) do
    with true <- value_segment?(id) and value_segment?(suffix),
         {:ok, timeout} <- value_timeout(opts) do
      case Concord.KV.get(value_key(id, suffix),
             engine: :turso,
             metadata: true,
             timeout: timeout
           ) do
        {:ok, %Concord.KV.Record{value: value, mod_revision: revision}}
        when is_integer(revision) and revision > 0 ->
          {:ok, %{value: value, revision: revision}}

        {:error, :not_found} ->
          :not_found

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_record}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    _, _ -> {:error, :storage_unavailable}
  end

  @doc """
  Replace an opaque session-scoped value once against its observed revision.

  Uses the same segment and timeout rules as `value_snapshot/3`. Revision zero
  means absent; positive revisions fence the observed stored value. A native
  conflict returns `{:error, :conflict}` without retry or readback.

  The finite timeout is requested, not a hard interruption or no-late-write
  guarantee. An admitted write can complete after timeout, so a timeout alone
  does not prove no write. A known late successful acknowledgement stays `:ok`.
  """
  @spec put_value_if_revision(binary(), binary(), term(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def put_value_if_revision(id, suffix, replacement, expected_revision, opts \\ []) do
    with true <- value_segment?(id) and value_segment?(suffix),
         true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, timeout} <- value_timeout(opts) do
      case KV.compare_and_swap(value_key(id, suffix), replacement,
             mod_revision: expected_revision,
             timeout: timeout
           ) do
        {:ok, %{succeeded: true}} -> :ok
        {:ok, %{succeeded: false}} -> {:error, :conflict}
        {:error, _} = error -> error
        _ -> {:error, :unknown_outcome}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  defp value_segment?(segment) when is_binary(segment) do
    byte_size(segment) in 1..4_096 and String.valid?(segment) and
      segment not in [".", ".."] and not String.contains?(segment, ["/", "\\", <<0>>])
  end

  defp value_segment?(_), do: false

  defp value_timeout([]), do: {:ok, 5_000}

  defp value_timeout([{:timeout, timeout}]) when is_integer(timeout) and timeout in 1..5_000,
    do: {:ok, timeout}

  defp value_timeout(_), do: {:error, :invalid_input}

  @doc "Write a session-scoped value under `sessions/<id>/<suffix>`."
  def put_value(id, suffix, value) when is_binary(id) and is_binary(suffix) do
    case KV.put(value_key(id, suffix), value) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> normalize_error(other)
    end
  end

  @doc "Read a session-scoped value, returning `default` when absent."
  def get_value(id, suffix, default \\ nil) when is_binary(id) and is_binary(suffix) do
    case KV.get(value_key(id, suffix)) do
      {:ok, value} -> value
      _ -> default
    end
  end

  @doc "Read pending-input value and modification revision in one record observation."
  def read_pending_inputs(id, opts \\ []) when is_binary(id) do
    with {:ok, timeout} <- pending_inputs_timeout(opts) do
      case Concord.KV.get(value_key(id, "pending_inputs"),
             engine: :turso,
             metadata: true,
             timeout: timeout
           ) do
        {:ok, %Concord.KV.Record{value: entries, mod_revision: revision}}
        when is_integer(revision) and revision > 0 ->
          {:ok, {:present, entries, revision}}

        {:error, :not_found} ->
          {:ok, :absent}

        other ->
          normalize_error(other)
      end
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  @doc """
  Conditionally replace pending inputs against the observed modification revision.

  An acknowledged conflict did not write. Any dispatched transaction error is
  unknown and must not be retried. A finite timeout is requested, but underlying
  readiness and database calls can exceed it. This does not promise a hard caller
  deadline, rollback or prevention of a late transaction commit.
  """
  def compare_put_pending_inputs(id, expected, entries, opts \\ [])
      when is_binary(id) and is_list(entries) do
    key = value_key(id, "pending_inputs")

    comparison =
      case expected do
        :absent ->
          {:exists, key, :==, false}

        {:present, _current, revision} when is_integer(revision) and revision > 0 ->
          {:mod_revision, key, :==, revision}
      end

    spec = %{compare: [comparison], success: [{:put, key, entries, %{}}], failure: []}

    with {:ok, timeout} <- pending_inputs_timeout(opts) do
      pending_inputs_transaction(spec, timeout)
    end
  end

  @doc "Atomically install completion messages, metadata and the pending occurrence receipt."
  def commit_pending_completion(
        id,
        {:present, _entries, revision},
        entries,
        start_n,
        turns,
        expected_meta,
        meta,
        opts \\ []
      ) do
    indexed = Enum.with_index(turns, start_n)

    spec = %{
      compare:
        [
          {:mod_revision, value_key(id, "pending_inputs"), :==, revision},
          {:value, meta_key(id), :==, expected_meta}
        ] ++ Enum.map(indexed, fn {_turn, n} -> {:exists, turn_key(id, n), :==, false} end),
      success:
        Enum.map(indexed, fn {turn, n} -> {:put, turn_key(id, n), turn, %{}} end) ++
          [
            {:put, meta_key(id), meta, %{}},
            {:put, value_key(id, "pending_inputs"), entries, %{}}
          ],
      failure: []
    }

    with {:ok, timeout} <- pending_inputs_timeout(opts),
         do: pending_inputs_transaction(spec, timeout)
  end

  defp pending_inputs_timeout(opts) do
    case Keyword.get(opts, :timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, min(timeout, 5_000)}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp pending_inputs_transaction(spec, timeout) do
    case KV.txn(spec, timeout: timeout) do
      {:ok, %{succeeded: true}} -> :ok
      {:ok, %{succeeded: false}} -> {:error, :conflict}
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  # ── meta ─────────────────────────────────────────────────────────────────

  @doc """
  Atomically initialize fresh session metadata and its normal permission value.

  The only option is `:timeout` in 1..5000 milliseconds. An acknowledged existing
  session is `:already_exists`; errors after dispatch are `:unknown_outcome`.
  No write is retried or rolled back after an uncertain acknowledgement.
  """
  def initialize_session(id, meta, permission, opts \\ []) do
    with true <-
           value_segment?(id) and is_map(meta) and not is_struct(meta) and
             is_map(permission) and not is_struct(permission),
         {:ok, timeout} <- value_timeout(opts) do
      initialize_session_transaction(id, meta, permission, timeout)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp initialize_session_transaction(id, meta, permission, timeout) do
    spec = %{
      compare: [
        {:exists, meta_key(id), :==, false},
        {:exists, value_key(id, "permission"), :==, false}
      ],
      success: [
        {:put, meta_key(id), meta, %{}},
        {:put, value_key(id, "permission"), permission, %{}}
      ],
      failure: []
    }

    case Concord.Txn.commit(spec, engine: :turso, timeout: timeout) do
      {:ok, %{succeeded: true}} -> :ok
      {:ok, %{succeeded: false}} -> {:error, :already_exists}
      {:error, {:invalid_txn, _}} = error -> error
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  @doc "Write a session's metadata snapshot."
  def put_meta(id, meta) when is_binary(id) and is_map(meta) do
    case KV.put(meta_key(id), meta) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> normalize_error(other)
    end
  end

  @doc "List every session's metadata snapshot (scans all `sessions/*/meta` keys)."
  def list_metas do
    case KV.prefix_scan("sessions/") do
      {:ok, pairs} ->
        # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
        metas =
          for {key, value} <- pairs,
              String.ends_with?(key, "/meta"),
              do: Concord.Compression.decompress(value)

        {:ok, metas}

      other ->
        normalize_error(other)
    end
  end

  @doc "Read a session's metadata snapshot."
  def get_meta(id, opts \\ []) when is_binary(id) do
    case KV.get(meta_key(id), opts) do
      {:ok, meta} -> {:ok, meta}
      {:error, :not_found} -> {:error, :not_found}
      other -> normalize_error(other)
    end
  end

  @doc """
  Read a bounded page of canonical session UUID candidates without reading values.

  Options are `:cursor` (exclusive UUID), `:limit` (1..100, default 100), and an
  absolute monotonic millisecond `:deadline` (at most five seconds). Each of at
  most 512 key-only seeks has a one-key limit and Concord's bounded lookahead.
  Queued list admission waits for brief connection contention within the original
  remaining budget.
  After finding a UUID, the next seek skips its entire session prefix, including
  stored turns. Orphan session keys are candidates; registration is not storage's
  responsibility. Malformed-key budget exhaustion returns `:scan_limit` rather
  than an incomplete page with an unusable UUID continuation.

  Pages read current state independently and do not promise snapshot consistency.
  Concord 3.1.8 reads value-free metadata after database readiness; its one-time
  upgrade backfill can decode old records, and synchronous native work cannot be
  forcibly interrupted by the operation timeout.
  """
  def list_session_ids(opts \\ []) do
    with {:ok, cursor, limit, deadline} <- presence_options(opts) do
      start_key = if cursor, do: "sessions/" <> cursor <> "0", else: "sessions/"
      collect_session_ids(start_key, limit, deadline, @presence_seek_budget, [])
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    _, _ -> {:error, :storage_unavailable}
  end

  defp presence_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:cursor, :limit, :deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      cursor = Keyword.get(opts, :cursor)
      limit = Keyword.get(opts, :limit, 100)
      now = System.monotonic_time(:millisecond)
      deadline = Keyword.get(opts, :deadline, now + 5_000)

      if (is_nil(cursor) or canonical_session_id?(cursor)) and
           is_integer(limit) and limit in 1..100 and is_integer(deadline),
         do: {:ok, cursor, limit, min(deadline, now + 5_000)},
         else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp presence_options(_), do: {:error, :invalid_input}

  defp collect_session_ids(_start, _limit, _deadline, 0, _ids),
    do: {:error, :scan_limit}

  defp collect_session_ids(start_key, limit, deadline, budget, ids) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      {:error, :timeout}
    else
      case KV.list(
             range: {start_key, "sessions0"},
             limit: 1,
             keys_only: true,
             queue: true,
             timeout: timeout
           ) do
        {:ok, [], _} ->
          {:ok, session_id_page(ids, false)}

        {:ok, [%{key: key}], _} ->
          case candidate_session_id(key) do
            nil ->
              collect_session_ids(after_session_key(key), limit, deadline, budget - 1, ids)

            _id when length(ids) == limit ->
              {:ok, session_id_page(ids, true)}

            id ->
              collect_session_ids("sessions/" <> id <> "0", limit, deadline, budget - 1, [
                id | ids
              ])
          end

        other ->
          normalize_error(other)
      end
    end
  end

  defp candidate_session_id("sessions/" <> <<id::binary-size(36), "/", suffix::binary>>)
       when byte_size(suffix) > 0,
       do: if(canonical_session_id?(id), do: id)

  defp candidate_session_id(_), do: nil

  defp canonical_session_id?(id) when is_binary(id),
    do: match?({:ok, ^id}, Ecto.UUID.cast(id))

  defp canonical_session_id?(_), do: false

  defp session_id_page(ids, more) do
    %{
      session_ids: Enum.reverse(ids),
      next_cursor: if(more, do: List.first(ids)),
      has_more: more,
      truncated: false
    }
  end

  defp after_session_key(key) when byte_size(key) < 4_096, do: key <> <<0>>
  defp after_session_key(key), do: increment_session_key(key)

  defp increment_session_key(key) do
    prefix = binary_part(key, 0, byte_size(key) - 1)

    case :binary.last(key) do
      255 -> increment_session_key(prefix)
      byte -> prefix <> <<byte + 1>>
    end
  end

  # ── turns ────────────────────────────────────────────────────────────────

  @doc """
  Read a bounded page of durable stored turns in ascending index order.

  The session ID must be a canonical lowercase UUID. Options are a unique,
  closed keyword list: `:cursor` (exclusive integer index, 0..999999999999),
  `:limit` (1..100, default 20), `:deadline` (absolute monotonic milliseconds,
  clamped to at most five seconds from now), and `:max_bytes` (1..1048576,
  default 65536). A nil cursor starts at the beginning.

  At most 512 one-key, key-only seeks inspect only this session's turns prefix.
  List admission uses Concord's finite queue with the remaining shared timeout.
  Only canonical twelve-digit indexes are selected; sparse indexes are valid.
  One extra canonical key establishes `has_more` without reading its value.
  `next_cursor` is the last returned index only when `has_more` is true.
  Malformed-key budget exhaustion returns `:scan_limit`, a disappeared selected
  key returns `:stale_page`, and a nonmap turn returns `:invalid_record`.
  Storage failures return `:storage_unavailable`, preserving `:timeout`.

  `max_bytes` caps the sum of `:erlang.external_size/1` for the already-read,
  opaque turn maps. Exceeding it returns `:payload_too_large`, without a partial
  page. This is a returned payload bound, not a pre-decode allocation bound or
  a model-facing normalized output budget. No serialization is performed here.
  The shared deadline is checked after reads and before success; synchronous
  native work cannot be forcibly interrupted. Concord's one-time upgrade
  metadata backfill can also decode old values before database readiness.

  Each call reads current durable state independently, without a snapshot or
  stable pagination across compaction, import, or rewrites. This does not read
  live Worker state. Empty or missing namespaces return a true end; this API
  makes no claim about session existence or visibility.
  """
  def list_turn_page(id, opts \\ []) do
    with true <- canonical_session_id?(id),
         {:ok, cursor, limit, deadline, max_bytes} <- turn_page_options(opts) do
      prefix = turns_prefix(id)
      start_key = if is_nil(cursor), do: prefix, else: turn_key(id, cursor) <> <<0>>
      end_key = session_prefix(id) <> "turns0"

      with {:ok, keys, more} <-
             collect_turn_page_keys(
               prefix,
               start_key,
               end_key,
               limit,
               deadline,
               @turn_page_seek_budget,
               []
             ),
           {:ok, turns} <- read_turn_page_keys(keys, deadline, max_bytes, []),
           {:ok, _remaining} <- turn_page_remaining(deadline) do
        {:ok,
         %{
           turns: turns,
           next_cursor: if(more, do: List.last(turns).index),
           has_more: more,
           truncated: false
         }}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  @doc """
  Read a bounded page of the newest durable turns in ascending index order.

  Uses the canonical UUID, closed options, shared deadline, decoded payload
  budget and error contract of `list_turn_page/2`. A nil cursor starts at the
  newest stored turn; an integer cursor selects only strictly older indexes.
  `next_cursor` is the oldest returned index only when `has_more` is true.

  At most 512 descending one-key, key-only seeks use Concord's finite queue
  and the remaining shared timeout. Only canonical selected keys have their
  values read; one older canonical key establishes `has_more` without a value
  read. Returned turns remain opaque maps, and `truncated` is always false.

  The byte budget sums already-decoded `:erlang.external_size/1` values, not
  pre-decode allocations. Native work cannot be forcibly interrupted. Each
  call observes current durable state independently, without snapshot or live
  Worker guarantees. An empty namespace makes no session-existence claim.
  """
  def list_recent_turn_page(id, opts \\ []) do
    with true <- canonical_session_id?(id),
         {:ok, cursor, limit, deadline, max_bytes} <- turn_page_options(opts) do
      prefix = turns_prefix(id)
      end_key = if is_nil(cursor), do: session_prefix(id) <> "turns0", else: turn_key(id, cursor)

      with {:ok, keys, more} <-
             collect_recent_turn_page_keys(
               prefix,
               end_key,
               limit,
               deadline,
               @turn_page_seek_budget,
               []
             ),
           {:ok, turns} <- read_turn_page_keys(keys, deadline, max_bytes, []),
           {:ok, _remaining} <- turn_page_remaining(deadline) do
        {:ok,
         %{
           turns: turns,
           next_cursor: if(more, do: List.first(turns).index),
           has_more: more,
           truncated: false
         }}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  defp turn_page_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:cursor, :limit, :deadline, :max_bytes] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      cursor = Keyword.get(opts, :cursor)
      limit = Keyword.get(opts, :limit, 20)
      max_bytes = Keyword.get(opts, :max_bytes, 65_536)
      now = System.monotonic_time(:millisecond)
      deadline = Keyword.get(opts, :deadline, now + 5_000)

      if (is_nil(cursor) or (is_integer(cursor) and cursor in 0..999_999_999_999)) and
           is_integer(limit) and limit in 1..100 and is_integer(deadline) and
           is_integer(max_bytes) and max_bytes in 1..1_048_576,
         do: {:ok, cursor, limit, min(deadline, now + 5_000), max_bytes},
         else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp turn_page_options(_), do: {:error, :invalid_input}

  defp collect_turn_page_keys(_prefix, _start, _end, _limit, _deadline, 0, _keys),
    do: {:error, :scan_limit}

  defp collect_turn_page_keys(_prefix, start_key, end_key, _limit, deadline, _budget, keys)
       when start_key >= end_key do
    with {:ok, _remaining} <- turn_page_remaining(deadline),
         do: {:ok, Enum.reverse(keys), false}
  end

  defp collect_turn_page_keys(prefix, start_key, end_key, limit, deadline, budget, keys) do
    with {:ok, timeout} <- turn_page_remaining(deadline),
         result <-
           KV.list(
             range: {start_key, end_key},
             limit: 1,
             keys_only: true,
             queue: true,
             timeout: timeout
           ),
         {:ok, _remaining} <- turn_page_remaining(deadline) do
      case result do
        {:ok, [], _} ->
          {:ok, Enum.reverse(keys), false}

        {:ok, [%{key: key}], _} when is_binary(key) ->
          index = canonical_turn_page_index(key, prefix)

          cond do
            not is_nil(index) and length(keys) == limit ->
              {:ok, Enum.reverse(keys), true}

            true ->
              next_keys = if is_nil(index), do: keys, else: [{key, index} | keys]

              collect_turn_page_keys(
                prefix,
                after_session_key(key),
                end_key,
                limit,
                deadline,
                budget - 1,
                next_keys
              )
          end

        other ->
          turn_page_storage_error(other)
      end
    end
  end

  defp collect_recent_turn_page_keys(_prefix, _end, _limit, _deadline, 0, _keys),
    do: {:error, :scan_limit}

  defp collect_recent_turn_page_keys(prefix, end_key, _limit, deadline, _budget, keys)
       when prefix >= end_key do
    with {:ok, _remaining} <- turn_page_remaining(deadline),
         do: {:ok, keys, false}
  end

  defp collect_recent_turn_page_keys(prefix, end_key, limit, deadline, budget, keys) do
    with {:ok, timeout} <- turn_page_remaining(deadline),
         result <-
           KV.list(
             range: {prefix, end_key},
             order: :desc,
             limit: 1,
             keys_only: true,
             queue: true,
             timeout: timeout
           ),
         {:ok, _remaining} <- turn_page_remaining(deadline) do
      case result do
        {:ok, [], _} ->
          {:ok, keys, false}

        {:ok, [%{key: key}], _} when is_binary(key) ->
          index = canonical_turn_page_index(key, prefix)

          cond do
            not is_nil(index) and length(keys) == limit ->
              {:ok, keys, true}

            true ->
              next_keys = if is_nil(index), do: keys, else: [{key, index} | keys]

              collect_recent_turn_page_keys(
                prefix,
                key,
                limit,
                deadline,
                budget - 1,
                next_keys
              )
          end

        other ->
          turn_page_storage_error(other)
      end
    end
  end

  defp canonical_turn_page_index(key, prefix) do
    if byte_size(key) == byte_size(prefix) + @turn_pad and String.starts_with?(key, prefix) do
      suffix = binary_part(key, byte_size(prefix), @turn_pad)
      if Regex.match?(~r/\A[0-9]{12}\z/, suffix), do: String.to_integer(suffix)
    end
  end

  defp read_turn_page_keys([], deadline, _remaining_bytes, turns) do
    with {:ok, _remaining} <- turn_page_remaining(deadline),
         do: {:ok, Enum.reverse(turns)}
  end

  defp read_turn_page_keys([{key, index} | keys], deadline, remaining_bytes, turns) do
    with {:ok, timeout} <- turn_page_remaining(deadline),
         result <- KV.get(key, timeout: timeout),
         {:ok, _remaining} <- turn_page_remaining(deadline) do
      case result do
        {:ok, turn} when is_map(turn) ->
          bytes = :erlang.external_size(turn)

          with {:ok, _remaining} <- turn_page_remaining(deadline) do
            if bytes <= remaining_bytes do
              read_turn_page_keys(keys, deadline, remaining_bytes - bytes, [
                %{index: index, turn: turn} | turns
              ])
            else
              {:error, :payload_too_large}
            end
          end

        {:ok, _nonmap} ->
          {:error, :invalid_record}

        {:error, :not_found} ->
          {:error, :stale_page}

        other ->
          turn_page_storage_error(other)
      end
    end
  end

  defp turn_page_remaining(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :timeout}
  end

  defp turn_page_storage_error({:error, :timeout}), do: {:error, :timeout}
  defp turn_page_storage_error(_), do: {:error, :storage_unavailable}

  @doc "Read a single turn by number."
  def get_turn(id, n) when is_binary(id) and is_integer(n) and n >= 0 do
    case KV.get(turn_key(id, n)) do
      {:ok, turn} -> {:ok, turn}
      {:error, :not_found} -> {:error, :not_found}
      other -> normalize_error(other)
    end
  end

  @doc """
  Range read of all turns for a session, returned in ascending turn order.

  Sorts by key because `Concord.Turso.prefix_scan/1` does not guarantee ascending
  order (see module note).
  """
  def list_turns(id) when is_binary(id) do
    case KV.prefix_scan(turns_prefix(id)) do
      {:ok, pairs} ->
        # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
        turns =
          pairs
          |> Enum.sort_by(fn {k, _v} -> k end)
          |> Enum.map(fn {_k, v} -> Concord.Compression.decompress(v) end)

        {:ok, turns}

      other ->
        normalize_error(other)
    end
  end

  @doc """
  Read at most `limit` newest turns in ascending order without enumerating or
  decoding the older inventory. Descending key-only seeks request at most the
  remaining count, paginating at Concord's 10,000-key limit. Each seek uses a
  finite five-second queued timeout; this is not a shared whole-call deadline.
  Selected values retain the existing batched read/decompression path.
  """
  @spec list_recent_turns(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_recent_turns(id, limit)
      when is_binary(id) and is_integer(limit) and limit > 0 do
    with {:ok, keys} <- list_recent_turn_keys(id, limit) do
      read_turn_keys(keys)
    end
  end

  @doc "Count durable turns without decoding their payloads."
  def count_turns(id) when is_binary(id) do
    case KV.prefix_scan(turns_prefix(id)) do
      {:ok, pairs} -> {:ok, length(pairs)}
      other -> normalize_error(other)
    end
  end

  @doc """
  Atomically commit a whole turn: writes the turn entry and the updated session
  meta snapshot together via `Concord.Turso.put_many/2`; the turn and meta
  either both land or neither does (all-or-nothing).

  Turn writes are keyed by turn number, so re-committing the same turn is
  naturally idempotent at the data level (the same key is overwritten in place);
  no separate idempotency token is required for the snapshot model.
  """
  def commit_turn(id, n, turn, meta)
      when is_binary(id) and is_integer(n) and n >= 0 and is_map(turn) and is_map(meta) do
    case KV.put_many([{turn_key(id, n), turn}, {meta_key(id), meta}]) do
      {:ok, _results} -> :ok
      :ok -> :ok
      other -> normalize_error(other)
    end
  end

  @doc """
  Atomically append a turn's messages and metadata at a fixed durable offset.

  The session process owns the offset. Recommitting the same turn is idempotent;
  earlier transcript entries are never scanned or rewritten. Oversized batches
  are rejected by Concord without splitting the atomic write.
  """
  def commit_turns(id, start_n, turn_maps, meta)
      when is_binary(id) and is_integer(start_n) and start_n >= 0 and
             is_list(turn_maps) and is_map(meta) do
    puts =
      turn_maps
      |> Enum.with_index(start_n)
      |> Enum.map(fn {turn, n} -> {turn_key(id, n), turn} end)

    case KV.put_many(puts ++ [{meta_key(id), meta}], timeout: 5_000) do
      {:ok, _results} -> :ok
      :ok -> :ok
      other -> normalize_error(other)
    end
  end

  @doc """
  Append one completed automation assistant turn at the session owner's offset.

  Reads the latest metadata and conditionally inserts the absent turn together
  with a timestamp-only metadata update. A concurrent metadata edit or occupied
  offset returns `:conflict` without writing. A transaction error after dispatch
  is `:unknown_outcome`; callers must not automatically retry it. This does not
  provide a hard transaction deadline or a cross-restart delivery receipt.
  """
  def append_automation_turn(id, next_index, turn, updated_at)
      when is_binary(id) and is_integer(next_index) and next_index >= 0 and is_map(turn) do
    with {:ok, current} <- get_meta(id, timeout: 5_000) do
      timestamp_key = if Map.has_key?(current, "updated_at"), do: "updated_at", else: :updated_at
      updated = Map.put(current, timestamp_key, updated_at)

      spec = %{
        compare: [
          {:value, meta_key(id), :==, current},
          {:exists, turn_key(id, next_index), :==, false}
        ],
        success: [
          {:put, turn_key(id, next_index), turn, %{}},
          {:put, meta_key(id), updated, %{}}
        ],
        failure: []
      }

      append_automation_transaction(spec, updated)
    end
  end

  defp append_automation_transaction(spec, updated) do
    case KV.txn(spec, timeout: 5_000) do
      {:ok, %{succeeded: true}} -> {:ok, updated}
      {:ok, %{succeeded: false}} -> {:error, :conflict}
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  @doc """
  Replace the full ordered turn list for a session in one atomic batch: drops the
  existing `turns/*` and writes `turns/0..n-1` from `turn_maps`; session meta is
  untouched. Used by the message write path (a message == a turn).

  Requests one five-second operation budget. Native work can finish after that
  budget; a known successful acknowledgement remains `:ok`. An error does not
  prove rollback or no effect, so uncertain outcomes must be reconciled before
  retrying. This wrapper never retries or falls back to separate writes.
  """
  def replace_turns(id, turn_maps) when is_binary(id) and is_list(turn_maps) do
    new_puts =
      turn_maps
      |> Enum.with_index()
      |> Enum.map(fn {turn, n} -> {turn_key(id, n), turn} end)

    case KV.replace_prefix(turns_prefix(id), new_puts, timeout: 5_000) do
      {:ok, %{succeeded: true}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  @doc """
  Replace the full ordered turn list and related session metadata in one atomic
  publication. Only the turns prefix is removed; other session-scoped values
  remain untouched. An empty turn list still publishes the supplied metadata.

  Uses the same five-second budget and uncertain-outcome contract as
  `replace_turns/2`, without retrying or falling back to separate writes.
  """
  def replace_turns(id, turn_maps, meta)
      when is_binary(id) and is_list(turn_maps) and is_map(meta) do
    new_puts =
      turn_maps
      |> Enum.with_index()
      |> Enum.map(fn {turn, n} -> {turn_key(id, n), turn} end)

    puts = new_puts ++ [{meta_key(id), meta}]

    case KV.replace_prefix(turns_prefix(id), puts, timeout: 5_000) do
      {:ok, %{succeeded: true}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  @doc "Delete a whole session: meta, turns, and every session-scoped value."
  def delete_session(id) when is_binary(id) do
    keys =
      case KV.prefix_scan(session_prefix(id)) do
        {:ok, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
        _ -> []
      end

    keys = Enum.uniq([meta_key(id) | keys])

    keys
    |> Enum.chunk_every(concord_batch_size())
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case KV.delete_many(chunk) do
        {:ok, _} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        other -> {:halt, normalize_error(other)}
      end
    end)
  end

  defp concord_batch_size do
    case Application.get_env(:concord, :max_batch_size, @default_batch_size) do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_batch_size
    end
  end

  defp list_recent_turn_keys(id, limit) do
    prefix = turns_prefix(id)
    collect_recent_turn_keys(prefix, prefix <> "\u{10FFFF}", limit, [])
  end

  defp collect_recent_turn_keys(start_key, end_key, limit, tail) do
    case KV.list(
           range: {start_key, end_key},
           order: :desc,
           limit: min(limit, @list_page_size),
           keys_only: true,
           queue: true,
           timeout: 5_000
         ) do
      {:ok, records, cursor} ->
        keys = Enum.map(records, & &1.key)
        next_tail = Enum.reverse(keys, tail)
        remaining = limit - length(keys)

        case cursor do
          %{has_more: true, last_key: last_key} when remaining > 0 and is_binary(last_key) ->
            collect_recent_turn_keys(start_key, last_key, remaining, next_tail)

          _ ->
            {:ok, next_tail}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_turn_keys([]), do: {:ok, []}

  defp read_turn_keys(keys) do
    keys
    |> Enum.chunk_every(concord_batch_size())
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, values} ->
      case KV.get_many(chunk) do
        {:ok, chunk_values} -> {:cont, {:ok, Map.merge(values, chunk_values)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> decode_turn_keys(keys)
  end

  defp decode_turn_keys({:error, reason}, _keys), do: {:error, reason}

  defp decode_turn_keys({:ok, values}, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, turns} ->
      case Map.fetch(values, key) do
        {:ok, {:ok, value}} ->
          {:cont, {:ok, [Concord.Compression.decompress(value) | turns]}}

        {:ok, {:error, reason}} ->
          {:halt, {:error, reason}}

        :error ->
          {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, turns} -> {:ok, Enum.reverse(turns)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── readiness ────────────────────────────────────────────────────────────

  @doc """
  Block until the embedded node-local store is up and serving, or return
  `{:error, :not_ready}` after `timeout` ms.

  Concord starts the Turso pool during application boot. This returns as soon
  as the store answers a probe (or its data is absent, which is still "ready").
  """
  def ensure_started(timeout \\ 10_000), do: wait_until_ready(timeout)

  @doc """
  Block until the node-local Concord store can serve requests, or return
  `{:error, :not_ready}` after `timeout` ms.
  """
  def wait_until_ready(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(deadline)
  end

  defp do_wait(deadline) do
    case KV.get("__synapsis_readiness_probe__") do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          do_wait(deadline)
        else
          {:error, :not_ready}
        end
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp normalize_error({:error, reason}), do: {:error, reason}
  defp normalize_error(other), do: {:error, other}
end
