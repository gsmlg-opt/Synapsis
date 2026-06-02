defmodule Synapsis.Session.Snapshot do
  @moduledoc """
  Per-turn session snapshotting to the node-local Concord store (ADR-006 B1).

  The live process holds truth during a turn. At the turn boundary the session
  is written to Concord — `meta` plus one `turns/<n>` entry per message — via
  `Session.Store`, whose `commit_turn/4` applies each turn as a single atomic
  Raft command (turn + meta together, never a half turn). `snapshot_async/1`
  does this **fire-and-forget** so the worker never blocks on durability.

  Rehydrate reads `meta` + ordered `turns/*` back; an absent snapshot means the
  session is idle at the prior turn and waits for input (no re-run, no
  tool double-apply — the agent's ground truth is files/git).

  NOTE: the read-authority inversion (process-as-truth for live reads) is B2;
  here the snapshot path is additive alongside the existing message store.
  """
  require Logger

  alias Synapsis.Session.Store
  alias Synapsis.{Session, Message}

  @doc """
  Build the durable `meta` snapshot for a session.

  Carries the full session fields (so `Sessions.from_meta/1` can reconstruct a
  `%Session{}`) plus the turn count and a snapshot timestamp.
  """
  def build_meta(%Session{} = session, turn_count) when is_integer(turn_count) do
    Session.to_meta(session, %{
      turn_count: turn_count,
      snapshotted_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  @doc """
  Snapshot the session to Concord: each persisted message becomes `turns/<n>`
  and a `meta` snapshot is written. Idempotent by turn index (re-snapshotting
  overwrites in place). Returns `:ok` or `{:error, reason}`.
  """
  def snapshot_session(session_id) when is_binary(session_id) do
    case Store.get_meta(session_id) do
      {:error, :not_found} ->
        {:error, :session_not_found}

      {:ok, meta} ->
        messages = Message.list_by_session(session_id)
        meta = Map.put(meta, :turn_count, length(messages))
        write_turns(session_id, messages, meta)
    end
  end

  @doc """
  Fire-and-forget snapshot for the turn boundary. Runs under the provider task
  supervisor and never blocks or crashes the caller.
  """
  def snapshot_async(session_id) when is_binary(session_id) do
    Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
      try do
        case snapshot_session(session_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("session_snapshot_failed",
              session_id: session_id,
              reason: inspect(reason)
            )
        end
      rescue
        e ->
          Logger.warning("session_snapshot_crashed",
            session_id: session_id,
            error: Exception.message(e)
          )
      end
    end)

    :ok
  end

  @doc """
  Rehydrate a session's durable state from Concord: `meta` + ordered turns.
  Returns `{:ok, %{meta: map, turns: [map]}}` or `{:error, :no_snapshot}`.
  """
  def rehydrate(session_id) when is_binary(session_id) do
    case Store.get_meta(session_id) do
      {:ok, meta} ->
        case Store.list_turns(session_id) do
          {:ok, turns} -> {:ok, %{meta: meta, turns: turns}}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :no_snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Encode a persisted message into a JSON-friendly turn map."
  def encode_message(%Message{} = message) do
    %{
      role: message.role,
      token_count: message.token_count,
      parts: Enum.map(message.parts || [], &encode_part/1)
    }
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp write_turns(session_id, [], meta), do: Store.put_meta(session_id, meta)

  defp write_turns(session_id, messages, meta) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
      case Store.commit_turn(session_id, index, encode_message(message), meta) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp encode_part(%Synapsis.Part.Text{content: content}),
    do: %{type: "text", text: content || ""}

  defp encode_part(%Synapsis.Part.ToolUse{tool: name, tool_use_id: id, input: input}),
    do: %{type: "tool_use", id: id, name: name, input: input || %{}}

  defp encode_part(%Synapsis.Part.ToolResult{tool_use_id: id, content: content, is_error: err}),
    do: %{type: "tool_result", tool_use_id: id, content: content || "", is_error: err || false}

  defp encode_part(%Synapsis.Part.Image{media_type: mt}),
    do: %{type: "image", media_type: mt}

  defp encode_part(other), do: %{type: "unknown", raw: inspect(other)}
end
