defmodule Synapsis.Memory.Writer do
  @moduledoc """
  PubSub subscriber that captures domain events and persists them as memory events.
  Implements the observer pattern — the agent loop does not change.
  """
  use GenServer
  require Logger

  @pubsub Synapsis.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # Subscribe to wildcard-matching topics via a registry-like pattern
    # We subscribe to specific topics dynamically as sessions start
    {:ok,
     %{
       subscriptions: MapSet.new(),
       intent_jobs: %{},
       intent_queues: %{},
       intent_active: %{},
       intent_tasks: %{},
       intent_callers: %{}
     }}
  end

  # Critical domain work is outside the optional observer persistence/rescue lane.
  # The Writer retains ownership, while the existing task supervisor runs I/O.
  @impl true
  def handle_call({:standing_intent, command, context}, from, state) do
    remaining = context.deadline - System.monotonic_time(:millisecond)

    if context.caller == elem(from, 0) and remaining > 0 do
      id = make_ref()
      caller_ref = Process.monitor(context.caller)
      timer = Process.send_after(self(), {:intent_deadline, context.agent_id, id}, remaining)

      job = %{
        id: id,
        from: from,
        command: command,
        context: Map.put(context, :owner, self()),
        caller_ref: caller_ref,
        timer: timer,
        task: nil,
        result: :pending
      }

      queue = :queue.in(id, Map.get(state.intent_queues, context.agent_id, :queue.new()))

      state = %{
        state
        | intent_jobs: Map.put(state.intent_jobs, id, job),
          intent_queues: Map.put(state.intent_queues, context.agent_id, queue),
          intent_callers: Map.put(state.intent_callers, caller_ref, id)
      }

      {:noreply, dispatch_intent(context.agent_id, state)}
    else
      {:reply, {:error, :timeout}, state}
    end
  end

  @doc "Subscribe to events for a specific session."
  def subscribe_session(session_id) do
    GenServer.cast(__MODULE__, {:subscribe_session, session_id})
  end

  @doc "Unsubscribe from events for a specific session."
  def unsubscribe_session(session_id) do
    GenServer.cast(__MODULE__, {:unsubscribe_session, session_id})
  end

  @impl true
  def handle_cast({:subscribe_session, session_id}, state) do
    unless MapSet.member?(state.subscriptions, session_id) do
      Phoenix.PubSub.subscribe(@pubsub, "session:#{session_id}")
      Phoenix.PubSub.subscribe(@pubsub, "tool_effects:#{session_id}")
    end

    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, session_id)}}
  end

  def handle_cast({:unsubscribe_session, session_id}, state) do
    Phoenix.PubSub.unsubscribe(@pubsub, "session:#{session_id}")
    Phoenix.PubSub.unsubscribe(@pubsub, "tool_effects:#{session_id}")
    {:noreply, %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}}
  end

  # ── Tool effects ────────────────────────────────────────────────────

  @impl true
  def handle_info({:tool_effect, effect_type, payload}, state) do
    # Observability writes must never crash the Writer (repeated crashes would
    # escalate Memory.Supervisor and take down the file adapter / event log).
    try do
      persist_event(%{
        scope: "session",
        scope_id: extract_session_id(payload),
        agent_id: Map.get(payload, :agent_id, "unknown"),
        type: map_tool_effect(effect_type),
        importance: importance_for(effect_type),
        payload: sanitize_payload(payload)
      })
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  # ── Session events ─────────────────────────────────────────────────

  def handle_info({:message_complete, session_id, _message}, state) do
    persist_event(%{
      scope: "session",
      scope_id: session_id,
      agent_id: "session_worker",
      type: "message_added",
      importance: 0.3,
      payload: %{}
    })

    {:noreply, state}
  end

  def handle_info({:status_changed, session_id, status}, state) do
    type =
      case status do
        :streaming -> "run_created"
        :idle -> "task_completed"
        :error -> "task_failed"
        _ -> nil
      end

    if type do
      persist_event(%{
        scope: "session",
        scope_id: session_id,
        agent_id: "session_worker",
        type: type,
        importance: if(status == :error, do: 0.8, else: 0.5),
        payload: %{status: to_string(status)}
      })
    end

    {:noreply, state}
  end

  def handle_info({:intent_start, id}, state) do
    case state.intent_jobs[id] do
      %{task: %Task{pid: pid}} -> send(pid, {:intent_start, id})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.fetch(state.intent_tasks, reference) do
      {:ok, id} ->
        # Task's result message precedes its DOWN. Do not demonitor or release
        # the Agent slot until actual process termination has been observed.
        job = Map.fetch!(state.intent_jobs, id)
        job = if job.result == :pending, do: %{job | result: result}, else: job
        {:noreply, %{state | intent_jobs: Map.put(state.intent_jobs, id, job)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    cond do
      id = state.intent_tasks[reference] ->
        job = Map.fetch!(state.intent_jobs, id)

        reply =
          case job.result do
            :pending -> {:error, {:unknown_outcome, :operation_exit}}
            known -> known
          end

        {:noreply, dispatch_intent(job.context.agent_id, retire_intent(state, job, reply))}

      id = state.intent_callers[reference] ->
        job = Map.fetch!(state.intent_jobs, id)

        if is_nil(job.task) do
          {:noreply,
           dispatch_intent(job.context.agent_id, retire_intent(state, %{job | from: nil}, nil))}
        else
          # Loss of reply transport is not proof that a dispatched write stopped.
          job = %{job | from: nil, caller_ref: nil}

          {:noreply,
           %{
             state
             | intent_jobs: Map.put(state.intent_jobs, id, job),
               intent_callers: Map.delete(state.intent_callers, reference)
           }}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:intent_deadline, agent_id, id}, state) do
    case state.intent_jobs[id] do
      %{context: %{agent_id: ^agent_id}, task: nil} = job ->
        {:noreply, dispatch_intent(agent_id, retire_intent(state, job, {:error, :timeout}))}

      %{context: %{agent_id: ^agent_id}} = job ->
        # A buffered known acknowledgement must survive this timer while DOWN
        # is pending. An earlier timeout is replied once; the slot stays owned.
        job =
          if job.result == :pending do
            reply_intent(job, {:error, {:unknown_outcome, :timeout}})
            %{job | from: nil, timer: nil}
          else
            %{job | timer: nil}
          end

        {:noreply, %{state | intent_jobs: Map.put(state.intent_jobs, id, job)}}

      _ ->
        {:noreply, state}
    end
  end

  # Catch-all for unknown messages
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.intent_jobs, fn {_id, job} ->
      if job.timer, do: Process.cancel_timer(job.timer)
      if job.task, do: Process.exit(job.task.pid, :shutdown)
    end)

    :ok
  end

  defp dispatch_intent(agent_id, state) do
    if Map.has_key?(state.intent_active, agent_id) do
      state
    else
      case :queue.out(Map.get(state.intent_queues, agent_id, :queue.new())) do
        {:empty, _} ->
          %{state | intent_queues: Map.delete(state.intent_queues, agent_id)}

        {{:value, id}, queue} ->
          state = %{state | intent_queues: Map.put(state.intent_queues, agent_id, queue)}

          case state.intent_jobs[id] do
            nil ->
              dispatch_intent(agent_id, state)

            job ->
              if job.context.deadline <= System.monotonic_time(:millisecond) or
                   not Process.alive?(job.context.caller) do
                dispatch_intent(agent_id, retire_intent(state, job, {:error, :timeout}))
              else
                start_intent(state, job)
              end
          end
      end
    end
  end

  defp start_intent(state, job) do
    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        # Starting a supervised child can itself have an ambiguous transport
        # outcome. No I/O begins until the Writer's recorded job sends this token.
        receive do
          {:intent_start, id} when id == job.id ->
            Synapsis.Memory.StandingIntents.perform(job.command, job.context)
        after
          max(0, job.context.deadline - System.monotonic_time(:millisecond)) ->
            {:error, :timeout}
        end
      end)

    state = %{
      state
      | intent_jobs: Map.put(state.intent_jobs, job.id, %{job | task: task}),
        intent_active: Map.put(state.intent_active, job.context.agent_id, job.id),
        intent_tasks: Map.put(state.intent_tasks, task.ref, job.id)
    }

    send(self(), {:intent_start, job.id})
    state
  rescue
    _ -> dispatch_intent(job.context.agent_id, retire_intent(state, job, {:error, :unavailable}))
  catch
    :exit, _ ->
      dispatch_intent(job.context.agent_id, retire_intent(state, job, {:error, :unavailable}))
  end

  defp retire_intent(state, job, reply) do
    if job.timer, do: Process.cancel_timer(job.timer)
    if job.caller_ref, do: Process.demonitor(job.caller_ref, [:flush])
    agent_id = job.context.agent_id
    queue = :queue.filter(&(&1 != job.id), Map.get(state.intent_queues, agent_id, :queue.new()))

    state = %{
      state
      | intent_jobs: Map.delete(state.intent_jobs, job.id),
        intent_queues:
          if(:queue.is_empty(queue),
            do: Map.delete(state.intent_queues, agent_id),
            else: Map.put(state.intent_queues, agent_id, queue)
          ),
        intent_active:
          if(state.intent_active[agent_id] == job.id,
            do: Map.delete(state.intent_active, agent_id),
            else: state.intent_active
          ),
        intent_tasks:
          if(job.task,
            do: Map.delete(state.intent_tasks, job.task.ref),
            else: state.intent_tasks
          ),
        intent_callers: Map.delete(state.intent_callers, job.caller_ref)
    }

    reply_intent(job, reply)
    state
  end

  defp reply_intent(%{from: nil}, _reply), do: :ok
  defp reply_intent(job, reply), do: GenServer.reply(job.from, reply)

  # ── Internals ───────────────────────────────────────────────────────

  defp persist_event(attrs) do
    _ = Synapsis.Memory.append_event(attrs)
    :ok
  rescue
    _ -> :ok
  end

  defp map_tool_effect(:file_changed), do: "tool_succeeded"
  defp map_tool_effect(:tool_called), do: "tool_called"
  defp map_tool_effect(:tool_result), do: "tool_succeeded"
  defp map_tool_effect(:tool_error), do: "tool_failed"
  defp map_tool_effect(other), do: to_string(other)

  defp importance_for(:tool_error), do: 0.8
  defp importance_for(:file_changed), do: 0.6
  defp importance_for(_), do: 0.5

  defp extract_session_id(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id(_), do: "unknown"

  defp sanitize_payload(payload) when is_map(payload) do
    payload
    |> Map.drop([:api_key, :secret, :token, :password, :credentials])
    |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_struct(v), do: inspect(v)
  defp safe_value(v) when is_tuple(v), do: inspect(v)
  defp safe_value(v) when is_pid(v), do: inspect(v)
  defp safe_value(v) when is_reference(v), do: inspect(v)
  defp safe_value(v) when is_function(v), do: "#Function"
  defp safe_value(v), do: v
end
