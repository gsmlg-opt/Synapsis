defmodule Synapsis.Agent.RunReducer do
  @moduledoc """
  Pure run lifecycle reducer.

  `reduce/2` has no store, PubSub, clock, provider, or tool side effects.
  Callers supply `occurred_at` and sequence on the event envelope.
  """

  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.Agent.RunState
  alias Synapsis.AgentRun

  @terminals AgentRun.terminal_statuses()

  @transitions %{
    "queued" => MapSet.new(~w(starting cancelled failed)),
    "starting" => MapSet.new(~w(running cancelled failed timed_out)),
    "running" =>
      MapSet.new(
        ~w(waiting_approval sleeping completed failed cancelled timed_out unknown_outcome)
      ),
    "waiting_approval" => MapSet.new(~w(running failed cancelled timed_out)),
    "sleeping" => MapSet.new(~w(running failed cancelled timed_out))
  }

  @event_status %{
    "run.created" => "queued",
    "run.starting" => "starting",
    "run.started" => "running",
    "run.waiting_approval" => "waiting_approval",
    "run.resumed" => "running",
    "run.sleeping" => "sleeping",
    "run.completed" => "completed",
    "run.failed" => "failed",
    "run.cancelled" => "cancelled",
    "run.timed_out" => "timed_out",
    "run.unknown_outcome" => "unknown_outcome",
    "run.reconciled" => nil,
    "run.side_effect_intent" => nil
  }

  @spec reduce(RunState.t(), RunEvent.t()) ::
          {:ok, RunState.t()} | {:error, atom()}
  def reduce(%RunState{} = state, %RunEvent{} = event) do
    cond do
      MapSet.member?(state.applied_event_ids, event.event_id) ->
        {:ok, state}

      true ->
        do_reduce(state, event)
    end
  end

  defp do_reduce(%RunState{run: run} = state, %RunEvent{} = event) do
    with :ok <- validate_sequence(run, event),
         {:ok, next_status} <- target_status(run, event),
         :ok <- validate_transition(run.status, next_status, event) do
      updated_run = apply_event(run, event, next_status)
      ids = MapSet.put(state.applied_event_ids, event.event_id)
      {:ok, %RunState{state | run: updated_run, applied_event_ids: ids}}
    end
  end

  defp validate_sequence(%AgentRun{last_event_sequence: last}, %RunEvent{sequence: seq})
       when is_integer(seq) and is_integer(last) do
    if seq > last do
      :ok
    else
      {:error, :stale_sequence}
    end
  end

  defp validate_sequence(_run, %RunEvent{sequence: nil}), do: {:error, :missing_sequence}
  defp validate_sequence(_run, _event), do: {:error, :stale_sequence}

  defp target_status(%AgentRun{} = run, %RunEvent{type: "run.reconciled"} = event) do
    case Map.get(event.payload, "status") || Map.get(event.payload, :status) do
      status when is_binary(status) ->
        if status in @terminals, do: {:ok, status}, else: {:error, :invalid_reconcile_status}

      _ ->
        if run.status in @terminals,
          do: {:ok, run.status},
          else: {:error, :invalid_reconcile_status}
    end
  end

  defp target_status(%AgentRun{status: status}, %RunEvent{type: "run.side_effect_intent"}) do
    {:ok, status}
  end

  defp target_status(_run, %RunEvent{type: type}) do
    case Map.fetch(@event_status, type) do
      {:ok, nil} -> {:error, :invalid_transition}
      {:ok, status} -> {:ok, status}
      :error -> {:error, :unknown_event_type}
    end
  end

  defp validate_transition(from, to, %RunEvent{type: type}) do
    cond do
      from == to and type in ~w(run.created run.side_effect_intent) ->
        :ok

      from == to and from in @terminals ->
        {:error, :contradictory_terminal}

      from in @terminals ->
        {:error, :already_terminal}

      type == "run.created" and from == "queued" and to == "queued" ->
        :ok

      MapSet.member?(Map.get(@transitions, from, MapSet.new()), to) ->
        :ok

      true ->
        {:error, :invalid_transition}
    end
  end

  defp apply_event(%AgentRun{} = run, %RunEvent{} = event, next_status) do
    payload = stringify_keys(event.payload || %{})
    recovery = run.recovery_state || %{}

    recovery =
      if event.type == "run.side_effect_intent" do
        Map.put(recovery, "side_effect_intent", true)
      else
        recovery
      end

    recovery =
      if next_status in @terminals do
        recovery
        |> Map.put("terminal_event_id", event.event_id)
        |> Map.put("terminal_status", next_status)
      else
        recovery
      end

    run
    |> Map.merge(%{
      status: next_status,
      last_event_sequence: event.sequence,
      revision: run.revision + 1,
      recovery_state: recovery
    })
    |> maybe_put_started(event, next_status)
    |> maybe_put_finished(event, next_status)
    |> maybe_put_summary(payload, next_status)
    |> maybe_put_error(payload, next_status)
  end

  defp maybe_put_started(run, event, status)
       when status in ~w(starting running waiting_approval) do
    started = run.started_at || event.occurred_at
    %{run | started_at: started}
  end

  defp maybe_put_started(run, _event, _status), do: run

  defp maybe_put_finished(run, event, status) when status in @terminals do
    %{run | finished_at: run.finished_at || event.occurred_at}
  end

  defp maybe_put_finished(run, _event, _status), do: run

  defp maybe_put_summary(run, payload, "completed") do
    summary = Map.get(payload, "summary") || run.summary
    %{run | summary: summary}
  end

  defp maybe_put_summary(run, _payload, _status), do: run

  defp maybe_put_error(run, payload, status)
       when status in ~w(failed timed_out unknown_outcome) do
    error = Map.get(payload, "error") || Map.get(payload, "reason") || run.error
    failure_class = Map.get(payload, "failure_class") || run.failure_class
    %{run | error: error, failure_class: failure_class}
  end

  defp maybe_put_error(run, _payload, _status), do: run

  defp stringify_keys(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
