defmodule Synapsis.Session.Read do
  @moduledoc """
  Read-path inversion (ADR-006 B2): the live `Session.Worker` is the read
  authority. `live_snapshot/1` returns the in-process snapshot when the session
  is running, and falls back to Concord's last durable turn when it is not.

  Readers (LiveView mount, REST/SSE, CLI) call this for the base view and then
  subscribe to PubSub for live deltas. Deltas broadcast from process state
  *before* the durable per-turn snapshot follows (fire-and-forget), so Concord
  may lag the latest broadcast by at most the in-flight turn — readers must not
  assume Concord reflects the newest broadcast. This reverses the old
  "persist-before-broadcast / DB is the source of truth" guardrail.
  """
  alias Synapsis.Session.{Snapshot, Worker}

  @typedoc "Result of a read-authority lookup."
  @type result ::
          {:live, map()}
          | {:durable, %{meta: map(), turns: [map()]}}
          | {:error, :not_found}

  @doc """
  Read the current session view from the read authority.

    * `{:live, snapshot}` — the running `Session.Worker` (includes the in-flight
      turn buffer)
    * `{:durable, %{meta:, turns:}}` — Concord's last durable snapshot, when the
      process is down
    * `{:error, :not_found}` — neither a live process nor a durable snapshot
  """
  @spec live_snapshot(binary()) :: result()
  def live_snapshot(session_id) when is_binary(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{_pid, _}] ->
        try do
          {:live, Worker.snapshot(session_id)}
        catch
          # Process died between lookup and call — fall back to durable state.
          :exit, _ -> durable(session_id)
        end

      [] ->
        durable(session_id)
    end
  end

  @doc "True when a live session process is the current read authority."
  @spec live?(binary()) :: boolean()
  def live?(session_id) when is_binary(session_id) do
    match?([{_pid, _}], Registry.lookup(Synapsis.Session.Registry, session_id))
  end

  defp durable(session_id) do
    case Snapshot.rehydrate(session_id) do
      {:ok, durable} -> {:durable, durable}
      {:error, :no_snapshot} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end
end
