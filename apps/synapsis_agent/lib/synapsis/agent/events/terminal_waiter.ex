defmodule Synapsis.Agent.Events.TerminalWaiter do
  @moduledoc """
  Await typed session-terminal events in the **same process** that subscribes.

  Deduplicates by `event_id`, correlates by `session_id` (and optional `run_id`),
  and ignores turn-complete / wrong-session events.
  """

  alias Synapsis.Agent.Events.RunEvent

  @type outcome ::
          {:completed, RunEvent.t()}
          | {:failed, RunEvent.t()}
          | {:cancelled, RunEvent.t()}
          | {:timed_out, RunEvent.t()}
          | {:waiter_timeout, String.t()}

  @doc """
  Subscribe to `session:<id>`, wait for a session-terminal typed event, then unsubscribe.

  Options:

  - `:timeout_ms` — waiter timeout (default 120_000)
  - `:run_id` — when set, reject terminals for a different run
  - `:seen_event_ids` — `MapSet` of already-handled event IDs (idempotent replay)
  """
  @spec await(String.t(), keyword()) :: outcome()
  def await(session_id, opts \\ []) when is_binary(session_id) do
    await_after(session_id, opts, fn -> :ok end)
  end

  @doc """
  Subscribe first, run `fun`, then wait for a session-terminal event.

  Use this when the triggering action (e.g. `send_message`) must not race ahead
  of the PubSub subscription.
  """
  @spec await_after(String.t(), (-> term())) :: outcome() | {:trigger_error, term()}
  def await_after(session_id, fun) when is_binary(session_id) and is_function(fun, 0) do
    await_after(session_id, [], fun)
  end

  @spec await_after(String.t(), keyword(), (-> term())) :: outcome() | {:trigger_error, term()}
  def await_after(session_id, opts, fun)
      when is_binary(session_id) and is_list(opts) and is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    run_id = Keyword.get(opts, :run_id)
    seen = Keyword.get(opts, :seen_event_ids, MapSet.new())
    topic = "session:#{session_id}"
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

    try do
      case fun.() do
        :ok ->
          do_await(session_id, run_id, seen, deadline)

        {:ok, _} ->
          do_await(session_id, run_id, seen, deadline)

        {:error, reason} ->
          {:trigger_error, reason}

        other ->
          {:trigger_error, other}
      end
    after
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
      flush_session_mailbox(session_id)
    end
  end

  @doc "Return true when a typed event matches the waiter correlation."
  @spec matches?(RunEvent.t(), String.t(), String.t() | nil) :: boolean()
  def matches?(%RunEvent{} = event, session_id, run_id \\ nil) do
    RunEvent.session_terminal?(event) and
      event.session_id == session_id and
      (is_nil(run_id) or is_nil(event.run_id) or event.run_id == run_id)
  end

  @doc "Classify a matching terminal event into an outcome tag."
  @spec classify(RunEvent.t()) :: :completed | :failed | :cancelled | :timed_out
  def classify(%RunEvent{type: "session.completed"}), do: :completed
  def classify(%RunEvent{type: "session.failed"}), do: :failed
  def classify(%RunEvent{type: "session.cancelled"}), do: :cancelled
  def classify(%RunEvent{type: "session.timed_out"}), do: :timed_out

  defp do_await(session_id, run_id, seen, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:waiter_timeout, "timed out waiting for session #{session_id}"}
    else
      receive do
        {:run_event, %RunEvent{} = event} ->
          cond do
            MapSet.member?(seen, event.event_id) ->
              do_await(session_id, run_id, seen, deadline)

            matches?(event, session_id, run_id) ->
              {classify(event), event}

            true ->
              do_await(session_id, run_id, seen, deadline)
          end

        _other ->
          do_await(session_id, run_id, seen, deadline)
      after
        remaining ->
          {:waiter_timeout, "timed out waiting for session #{session_id}"}
      end
    end
  end

  defp flush_session_mailbox(session_id) do
    receive do
      {:run_event, %RunEvent{session_id: ^session_id}} -> flush_session_mailbox(session_id)
      {"done", _} -> flush_session_mailbox(session_id)
      {"error", _} -> flush_session_mailbox(session_id)
      {"session_status", _} -> flush_session_mailbox(session_id)
    after
      0 -> :ok
    end
  end
end
