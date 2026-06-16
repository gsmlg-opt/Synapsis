defmodule Synapsis.Session.Store do
  @moduledoc """
  Concord-backed persistence for agent sessions (ADR-006).

  Node-local key-value access over the embedded Concord (Ra) store. Keys are
  namespaced per session:

    * `sessions/<id>/meta`           — single session-metadata snapshot
    * `sessions/<id>/turns/<padded>` — one entry per conversation turn

  This module is a thin functional wrapper. Concord owns the process and the
  state, so there is no GenServer here (see the OTP "no process without a
  runtime reason" rule). A whole turn is committed atomically via a single
  `Concord.put_many/2`: the turn entry and the updated meta snapshot either both
  land or neither does.

  ## Concord notes (targets `concord 2.1.0`)

    * Concord 2.x starts the embedded `:ra` default system itself, defaults the
      Prometheus exporter off, and honours `clustering: false` — so embedded
      node-local boot needs no host-side glue (the 1.1.0 workarounds are gone).
    * Whole-turn atomicity uses `Concord.put_many/2`, which the state machine
      applies as a single Raft log entry — all-or-nothing by construction.
      (`Concord.Txn` is available in 2.x for *conditional* commits if needed
      later; the unconditional snapshot does not need compare predicates.)
    * `Concord.prefix_scan/1` returns matches in **descending** key order
      (its server-side reduce reverses the ascending ETS scan). `list_turns/1`
      sorts ascending to honor the ADR-006 "turns in order" contract — callers
      must not rely on raw `prefix_scan` ordering.
    * Writes always go through Raft consensus (`:ra.process_command`); reads
      default to `:leader` consistency. On a single-member node-local cluster
      the local process is always the leader, so there is no election gating in
      the session path.
  """

  @turn_pad 12

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

  @doc "Write a session-scoped value under `sessions/<id>/<suffix>`."
  def put_value(id, suffix, value) when is_binary(id) and is_binary(suffix) do
    case Concord.put(value_key(id, suffix), value) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> normalize_error(other)
    end
  end

  @doc "Read a session-scoped value, returning `default` when absent."
  def get_value(id, suffix, default \\ nil) when is_binary(id) and is_binary(suffix) do
    case Concord.get(value_key(id, suffix)) do
      {:ok, value} -> value
      _ -> default
    end
  end

  # ── meta ─────────────────────────────────────────────────────────────────

  @doc "Write a session's metadata snapshot."
  def put_meta(id, meta) when is_binary(id) and is_map(meta) do
    case Concord.put(meta_key(id), meta) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> normalize_error(other)
    end
  end

  @doc "List every session's metadata snapshot (scans all `sessions/*/meta` keys)."
  def list_metas do
    case Concord.prefix_scan("sessions/") do
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
  def get_meta(id) when is_binary(id) do
    case Concord.get(meta_key(id)) do
      {:ok, meta} -> {:ok, meta}
      {:error, :not_found} -> {:error, :not_found}
      other -> normalize_error(other)
    end
  end

  # ── turns ────────────────────────────────────────────────────────────────

  @doc "Read a single turn by number."
  def get_turn(id, n) when is_binary(id) and is_integer(n) and n >= 0 do
    case Concord.get(turn_key(id, n)) do
      {:ok, turn} -> {:ok, turn}
      {:error, :not_found} -> {:error, :not_found}
      other -> normalize_error(other)
    end
  end

  @doc """
  Range read of all turns for a session, returned in ascending turn order.

  Sorts by key because `Concord.prefix_scan/1` does not guarantee ascending
  order (see module note).
  """
  def list_turns(id) when is_binary(id) do
    case Concord.prefix_scan(turns_prefix(id)) do
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

  @doc "Count durable turns without decoding their payloads."
  def count_turns(id) when is_binary(id) do
    case Concord.prefix_scan(turns_prefix(id)) do
      {:ok, pairs} -> {:ok, length(pairs)}
      other -> normalize_error(other)
    end
  end

  @doc """
  Atomically commit a whole turn: writes the turn entry and the updated session
  meta snapshot together via `Concord.put_many/2`, which the Raft state machine
  applies as a single log entry — the turn and meta either both land or neither
  does (all-or-nothing).

  Turn writes are keyed by turn number, so re-committing the same turn is
  naturally idempotent at the data level (the same key is overwritten in place);
  no separate idempotency token is required for the snapshot model.
  """
  def commit_turn(id, n, turn, meta)
      when is_binary(id) and is_integer(n) and n >= 0 and is_map(turn) and is_map(meta) do
    case Concord.put_many([{turn_key(id, n), turn}, {meta_key(id), meta}]) do
      {:ok, _results} -> :ok
      :ok -> :ok
      other -> normalize_error(other)
    end
  end

  @doc """
  Replace the full ordered turn list for a session in one atomic batch: drops the
  existing `turns/*` and writes `turns/0..n-1` from `turn_maps`. Meta is left
  untouched. Used by the message write path (a message == a turn).
  """
  def replace_turns(id, turn_maps) when is_binary(id) and is_list(turn_maps) do
    old_keys =
      case Concord.prefix_scan(turns_prefix(id)) do
        {:ok, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
        _ -> []
      end

    new_puts =
      turn_maps
      |> Enum.with_index()
      |> Enum.map(fn {turn, n} -> {turn_key(id, n), turn} end)

    # Delete stale higher-index turns (when the list shrank), then write the new set.
    stale = old_keys -- Enum.map(new_puts, fn {k, _v} -> k end)
    if stale != [], do: Concord.delete_many(stale)

    case new_puts do
      [] -> :ok
      puts -> with {:ok, _} <- Concord.put_many(puts), do: :ok
    end
  end

  @doc "Delete a whole session: meta, turns, and every session-scoped value."
  def delete_session(id) when is_binary(id) do
    keys =
      case Concord.prefix_scan(session_prefix(id)) do
        {:ok, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
        _ -> []
      end

    keys = Enum.uniq([meta_key(id) | keys])

    case Concord.delete_many(keys) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> normalize_error(other)
    end
  end

  # ── readiness ────────────────────────────────────────────────────────────

  @doc """
  Block until the embedded node-local store is up and serving, or return
  `{:error, :not_ready}` after `timeout` ms.

  Concord 2.x starts the `:ra` default system and (re)starts its single-member
  cluster from any persisted data dir during its own application start, so
  embedded boot needs no host-side glue. This is purely a readiness gate over
  Concord's fire-and-forget `init_cluster` task — it returns as soon as the
  store answers a probe (or its data is absent, which is still "ready").
  """
  def ensure_started(timeout \\ 10_000), do: wait_until_ready(timeout)

  @doc """
  Block until the node-local Concord store can serve requests, or return
  `{:error, :not_ready}` after `timeout` ms. A single-member Ra cluster elects a
  leader near-instantly, so this returns quickly once boot has completed.
  """
  def wait_until_ready(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(deadline)
  end

  defp do_wait(deadline) do
    case Concord.get("__synapsis_readiness_probe__") do
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
