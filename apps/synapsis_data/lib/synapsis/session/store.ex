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
  Concord transaction: the turn entry and the updated meta snapshot either both
  land or neither does.

  ## Concord deltas captured during the B0 spike

    * The released Hex package (`concord 1.1.0`) does **not** ship the v2
      `Concord.Txn` / `Concord.KV` API advertised on the project's `main`
      branch. Whole-turn atomicity is therefore achieved with the v1
      `Concord.put_many/2`, which the state machine applies as a single Raft
      log entry — all-or-nothing by construction.
      `# TODO(upstream): gsmlg-dev/concord#18` (release the v2 `Txn` API).
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

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(@turn_pad, "0")

  # ── meta ─────────────────────────────────────────────────────────────────

  @doc "Write a session's metadata snapshot."
  def put_meta(id, meta) when is_binary(id) and is_map(meta) do
    case Concord.put(meta_key(id), meta) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> normalize_error(other)
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
        turns =
          pairs
          |> Enum.sort_by(fn {k, _v} -> k end)
          |> Enum.map(fn {_k, v} -> v end)

        {:ok, turns}

      other ->
        normalize_error(other)
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

  @doc "Delete a whole session: its meta snapshot and every turn."
  def delete_session(id) when is_binary(id) do
    turn_keys =
      case Concord.prefix_scan(turns_prefix(id)) do
        {:ok, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
        _ -> []
      end

    case Concord.delete_many([meta_key(id) | turn_keys]) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> normalize_error(other)
    end
  end

  # ── readiness ────────────────────────────────────────────────────────────

  @doc """
  Ensure the embedded node-local store is up and serving, then block until it is
  ready (or return `{:error, :not_ready}` after `timeout` ms).

  Works around three `concord 1.1.0` behaviours found during the B0/B1 spikes
  (all tracked in `# TODO(upstream): gsmlg-dev/concord#17`):

    * Concord does not start the `:ra` default system itself — its own suite
      relies on a test helper calling `:ra_system.start_default/0`. We start it
      here (idempotent).
    * Concord forms its cluster from a fire-and-forget `init_cluster` task at app
      start, which fails with `:system_not_started` if the ra system was not up
      yet.
    * `init_cluster` always uses `:ra.start_server`, which fails with `:not_new`
      when the ra data dir already holds state — i.e. **every node restart**,
      which is exactly the rehydrate path. We `:ra.restart_server` the existing
      server in that case; only if there is genuinely no server do we bounce the
      `:concord` app so its `init_cluster` re-runs.
  """
  @cluster_name :concord_cluster

  def ensure_started(timeout \\ 10_000) do
    _ = start_ra_default_system()

    case wait_until_ready(500) do
      :ok -> :ok
      {:error, :not_ready} -> recover_and_wait(timeout)
    end
  end

  # WORKAROUND(upstream): gsmlg-dev/concord#17
  defp recover_and_wait(timeout) do
    server_id = {@cluster_name, node()}

    case safe_restart_server(server_id) do
      :ok ->
        :ok

      _ ->
        # No restartable server (fresh data dir or never started): bounce the
        # app so Concord's init_cluster runs `start_server` against a clean dir.
        _ = Application.stop(:concord)
        {:ok, _} = Application.ensure_all_started(:concord)
        :ok
    end

    wait_until_ready(timeout)
  end

  defp safe_restart_server(server_id) do
    case :ra.restart_server(:default, server_id) do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  rescue
    _ -> {:error, :restart_failed}
  catch
    _, _ -> {:error, :restart_failed}
  end

  defp start_ra_default_system do
    case :ra_system.fetch(:default) do
      sys when is_map(sys) -> :ok
      _ -> :ra_system.start_default()
    end
  end

  @doc """
  Block until the node-local Concord store can serve requests, or return
  `{:error, :not_ready}` after `timeout` ms.

  Assumes the store is already started (see `ensure_started/1`); a single-member
  Ra cluster elects a leader near-instantly, so this returns quickly once boot
  has completed.
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
