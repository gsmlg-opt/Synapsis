defmodule Synapsis.Session.Worker.Checkpoint do
  @moduledoc """
  In-memory checkpoint stack for the session worker.

  Push is cheap: it captures the worker's engine fields by reference
  (immutable structural sharing), the durable turn count, and — when the
  session has a git workspace — a restorable ref via `Synapsis.Git`.
  The stack lives only in worker data; nothing is written to a separate
  durable key (GUARDRAILS NEVER #1), so checkpoints do not survive a
  worker restart.

  Rollback is a compaction-class operation (same cost profile as
  `Synapsis.Session.Compactor`, which also runs in the worker): it
  restores the workspace ref when one was captured, truncates the durable
  turns back to the checkpoint's turn count, appends a correction message,
  and rewinds the engine state.

  Rollback with an empty stack is the caller's error to surface at the
  call boundary; this module intentionally has no empty-stack clause —
  an internal rollback without a prior push is an invariant violation.
  """

  require Logger

  alias Synapsis.{Git, Message, Part}
  alias Synapsis.Session.Store

  def push(%{session_id: session_id} = state, reason) do
    with {:ok, turn_count} <- Store.count_turns(session_id) do
      checkpoint = %{
        id: Ecto.UUID.generate(),
        reason: reason,
        engine_node: state.engine_node,
        engine_state: state.engine_state,
        engine_ctx: state.engine_ctx,
        stream_acc: state.stream_acc,
        executed_tool_ids: state.executed_tool_ids || MapSet.new(),
        turn_count: turn_count,
        workspace_ref: capture_workspace(state),
        created_at: DateTime.utc_now()
      }

      {:ok, %{state | checkpoints: [checkpoint | state.checkpoints]}, checkpoint}
    end
  end

  def rollback(%{session_id: session_id, checkpoints: [checkpoint | rest]} = state, reason) do
    workspace = restore_workspace(state, checkpoint)

    restored_messages =
      session_id
      |> Message.list_by_session()
      |> Enum.take(checkpoint.turn_count)
      |> Kernel.++([rollback_message(checkpoint, reason, workspace)])

    with :ok <- Message.persist_list(session_id, restored_messages) do
      {:ok, restore_state(state, checkpoint, rest, reason, workspace), checkpoint}
    end
  end

  defp capture_workspace(%{project_path: path}) when is_binary(path) do
    case Git.capture_ref(path) do
      {:ok, ref} ->
        ref

      {:error, reason} ->
        Logger.info("checkpoint_workspace_degraded", reason: inspect(reason))
        :history_only
    end
  end

  defp capture_workspace(_state), do: :history_only

  defp restore_workspace(%{project_path: path}, %{workspace_ref: %{head: _} = ref})
       when is_binary(path) do
    case Git.restore_ref(path, ref) do
      :ok ->
        :restored

      {:error, reason} ->
        Logger.warning("checkpoint_workspace_restore_failed", reason: inspect(reason))
        :history_only
    end
  end

  defp restore_workspace(_state, _checkpoint), do: :history_only

  defp restore_state(state, checkpoint, rest, reason, workspace) do
    %{
      state
      | engine_node: checkpoint.engine_node,
        engine_state: checkpoint.engine_state,
        engine_ctx: restore_engine_ctx(checkpoint, reason, workspace),
        stream_acc: checkpoint.stream_acc,
        executed_tool_ids: checkpoint.executed_tool_ids,
        checkpoints: rest
    }
  end

  defp restore_engine_ctx(checkpoint, reason, workspace) do
    Map.put(checkpoint.engine_ctx, :checkpoint_rollback, %{
      id: checkpoint.id,
      reason: reason,
      workspace: workspace
    })
  end

  defp rollback_message(checkpoint, reason, workspace) do
    workspace_note =
      case workspace do
        :restored ->
          "Workspace files were restored to the checkpoint."

        :history_only ->
          "Workspace files were NOT rolled back — re-read any files modified since before continuing."
      end

    %Message{
      id: Ecto.UUID.generate(),
      role: "system",
      token_count: 0,
      inserted_at: DateTime.utc_now(),
      parts: [
        %Part.Text{
          content:
            "Checkpoint rollback #{checkpoint.id} restored session history. " <>
              "Reason: #{reason || "unspecified"}. #{workspace_note}"
        }
      ]
    }
  end
end
