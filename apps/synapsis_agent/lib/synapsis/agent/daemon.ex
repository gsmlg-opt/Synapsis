defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanently supervised FIFO coordinator for durable manual agent runs.

  The GenServer owns only queue and monitor state. Store, event, PubSub, and
  session work runs in unlinked tasks under `RunTaskSupervisor`.
  """

  use GenServer

  alias Synapsis.Agent.{RunEvents, Runs}
  alias Synapsis.Agent.Daemon.{Execution, Recovery}
  alias Synapsis.AgentRun
  alias Synapsis.Sessions

  @topic "agent:daemon"
  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor
  @queue_capacity 25
  @run_timeout :timer.minutes(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def topic, do: @topic
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) do
    with {:ok, attrs} <- Execution.manual_attrs(prompt, opts) do
      GenServer.call(server, {:submit, attrs})
    end
  end

  def cancel(run_id), do: cancel(__MODULE__, run_id)
  def cancel(server, run_id) when is_binary(run_id), do: GenServer.call(server, {:cancel, run_id})
  def cancel(_server, _run_id), do: {:error, :invalid_run_id}

  @impl true
  def init(opts) do
    config = Application.get_env(:synapsis_agent, __MODULE__, [])
    recover? = Keyword.get(opts, :recover?, true)

    state = %{
      ready: not recover?,
      active_run: nil,
      queue: :queue.new(),
      cancelling_ids: MapSet.new(),
      pending: %{},
      next_submit_seq: 0,
      next_submit_reply_seq: 0,
      submit_outcomes: %{},
      reconcile_retries: %{},
      recovery_backlog_count: 0,
      recovery_retry_ms: Keyword.get(opts, :recovery_retry_ms, 100),
      queue_capacity:
        opts
        |> Keyword.get(:queue_capacity, Keyword.get(config, :queue_capacity, @queue_capacity))
        |> Execution.valid_capacity(@queue_capacity),
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      run_timeout: Keyword.get(opts, :run_timeout, @run_timeout),
      deps: %{
        runs: Keyword.get(opts, :runs, Runs),
        run_events: Keyword.get(opts, :run_events, RunEvents),
        sessions: Keyword.get(opts, :sessions, Sessions)
      },
      last_error: nil,
      recovery_error: nil
    }

    send(self(), if(recover?, do: :recover, else: :status_changed))
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Execution.status(state), state}

  def handle_call({:submit, attrs}, from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      queue_load(state) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, state}

      true ->
        seq = state.next_submit_seq
        run_id = Ecto.UUID.generate()
        attrs = Map.put(attrs, :id, run_id)
        op = %{type: :submit, from: from, seq: seq, run_id: run_id}

        case start_operation(state, op, fn ->
               Execution.submit(state.deps, attrs)
             end) do
          {:ok, state} -> {:noreply, %{state | next_submit_seq: seq + 1}}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  def handle_call({:cancel, run_id}, from, state) do
    case locate_run(state, run_id) do
      {:active, active} when active.cancelling ->
        {:reply, {:error, :cancellation_in_progress}, state}

      {:active, active} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :active}

        case start_operation(state, op, fn ->
               Execution.cancel_active(state.deps, state.task_supervisor, active)
             end) do
          {:ok, state} ->
            active = %{active | cancelling: true}
            {:noreply, %{state | active_run: active}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      {:queued, run} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :queued}

        case start_operation(state, op, fn -> Execution.cancel_queued(state.deps, run) end) do
          {:ok, state} ->
            {:noreply, %{state | cancelling_ids: MapSet.put(state.cancelling_ids, run_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      :unknown ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :unknown}

        case start_operation(state, op, fn -> Execution.classify(state.deps.runs, run_id) end) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  @impl true
  def handle_info(:recover, state) do
    case start_operation(state, %{type: :recovery}, fn ->
           Recovery.run(state.deps, state.queue_capacity)
         end) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :recover, 25)
        {:noreply, state}
    end
  end

  def handle_info(:drain, %{active_run: nil} = state) do
    case :queue.peek(state.queue) do
      {:value, run} ->
        if MapSet.member?(state.cancelling_ids, run.id) do
          {:noreply, state}
        else
          case start_runner(state, run) do
            {:ok, task_pid, task_ref} ->
              {{:value, ^run}, queue} = :queue.out(state.queue)

              deadline_ref =
                Process.send_after(self(), {:run_deadline, run.id}, state.run_timeout)

              active = %{
                run: run,
                task_pid: task_pid,
                task_ref: task_ref,
                deadline_ref: deadline_ref,
                session_id: nil,
                phase: :starting,
                cancelling: false,
                degraded: false,
                error: nil
              }

              new_state = %{state | queue: queue, active_run: active}
              send(self(), :refill)
              {:noreply, new_state}

            {:error, reason} ->
              Process.send_after(self(), :drain, 100)
              new_state = put_error(state, {:run_task_start_failed, reason})
              dispatch_status(new_state)
              {:noreply, new_state}
          end
        end

      :empty ->
        {:noreply, state}
    end
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(:refill, state) do
    available = max(state.queue_capacity - queue_load(state), 0)

    cond do
      state.recovery_backlog_count <= 0 or available == 0 ->
        {:noreply, state}

      pending_type?(state, :refill) ->
        {:noreply, state}

      true ->
        excluded = owned_run_ids(state)
        op = %{type: :refill, reserved_slots: available}

        case start_operation(state, op, fn ->
               Recovery.refill(state.deps, excluded, available)
             end) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:noreply, schedule_refill_retry(state, reason)}
        end
    end
  end

  def handle_info(:status_changed, state) do
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:retry_submit_reconcile, seq}, state) do
    case Map.pop(state.reconcile_retries, seq) do
      {nil, _retries} ->
        {:noreply, state}

      {{op, reason}, retries} ->
        state = %{state | reconcile_retries: retries}
        {:noreply, start_submit_reconcile(state, op, reason)}
    end
  end

  def handle_info(
        {:session_created, task_pid, run_id, session_id},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    send(task_pid, {:session_created_ack, run_id})
    new_state = %{state | active_run: %{active | session_id: session_id}}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {:runner_started, task_pid, %AgentRun{} = run},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      )
      when run.id == run_id do
    send(task_pid, {:runner_started_ack, run.id})
    new_state = %{state | active_run: %{active | run: run, phase: :running}}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  def handle_info({:operation_result, task_pid, result}, state) do
    case pop_operation(state, task_pid) do
      {:ok, op, state} -> handle_operation_result(op, result, state)
      :error -> {:noreply, state}
    end
  end

  def handle_info(
        {:runner_result, task_pid, run_id, result},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    Process.demonitor(active.task_ref, [:flush])
    handle_runner_result(result, active, state)
  end

  def handle_info({:runner_result, _task_pid, _run_id, _result}, state), do: {:noreply, state}

  def handle_info(
        {:run_deadline, run_id},
        %{active_run: %{run: %{id: run_id}, cancelling: false, degraded: false} = active} = state
      ) do
    op = %{type: :timeout, run_id: run_id}

    case start_operation(state, op, fn ->
           Execution.timeout(state.deps, state.task_supervisor, active)
         end) do
      {:ok, state} ->
        active = %{active | deadline_ref: nil, cancelling: true, phase: :timing_out}
        {:noreply, %{state | active_run: active}}

      {:error, reason} ->
        Process.send_after(self(), {:run_deadline, run_id}, 25)
        new_state = put_error(state, {:timeout_task_start_failed, reason})
        dispatch_status(new_state)
        {:noreply, new_state}
    end
  end

  def handle_info({:run_deadline, _run_id}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      state.active_run && state.active_run.task_ref == ref ->
        handle_runner_down(pid, reason, state)

      true ->
        handle_operation_down(ref, reason, state)
    end
  end

  defp handle_operation_result(%{type: type} = op, result, state)
       when type in [:submit, :submit_reconcile] do
    outcomes = Map.put(state.submit_outcomes, op.seq, {op, result})
    {new_state, processed?} = flush_submit_outcomes(%{state | submit_outcomes: outcomes})

    if processed? do
      dispatch_status(new_state)
      send(self(), :drain)
    end

    {:noreply, new_state}
  end

  defp handle_operation_result(
         %{type: :cancel, from: from, run_id: id, location: location},
         {:ok, cancelled, errors},
         state
       ) do
    GenServer.reply(from, {:ok, cancelled})

    new_state =
      case location do
        :active ->
          cancel_deadline(state.active_run)
          %{state | active_run: nil}

        :queued ->
          %{state | queue: remove_queued(state.queue, id)}
      end
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, id))
      |> Map.put(:last_error, join_errors(errors))

    dispatch_status(new_state)
    send(self(), :drain)
    send(self(), :refill)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :cancel, from: from} = op, {:error, reason}, state) do
    GenServer.reply(from, {:error, reason})

    new_state =
      state
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, op.run_id))
      |> maybe_reset_cancelling(op)
      |> put_error(reason)

    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :timeout}, {:ok, terminal_run, errors}, state) do
    cancel_deadline(state.active_run)
    last_error = terminal_errors(terminal_run, errors)
    new_state = %{state | active_run: nil, last_error: last_error}
    dispatch_status(new_state)
    send(self(), :drain)
    send(self(), :refill)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :timeout}, {:error, reason, run}, state) do
    error = Execution.bounded_error(reason)
    active = state.active_run

    degraded = %{
      active
      | run: run || active.run,
        task_pid: nil,
        task_ref: nil,
        deadline_ref: nil,
        phase: :degraded,
        degraded: true,
        error: error
    }

    new_state = %{state | active_run: degraded, last_error: error}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :recovery}, {:ok, queued, backlog}, state) do
    new_state = %{
      state
      | ready: true,
        queue: :queue.from_list(queued),
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: nil
    }

    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :recovery}, {:retry, errors}, state),
    do: {:noreply, schedule_recovery_retry(state, errors)}

  defp handle_operation_result(%{type: :recovery}, {:error, reason}, state),
    do: {:noreply, schedule_recovery_retry(state, reason)}

  defp handle_operation_result(%{type: :refill}, {:ok, queued, backlog}, state) do
    queue = Enum.reduce(queued, state.queue, &:queue.in/2)

    new_state = %{
      state
      | ready: true,
        queue: queue,
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: nil
    }

    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :refill}, {:retry, errors}, state),
    do: {:noreply, schedule_refill_retry(state, errors)}

  defp handle_operation_result(%{type: :refill}, {:error, reason}, state),
    do: {:noreply, schedule_refill_retry(state, reason)}

  defp handle_runner_result({:ok, terminal_run, errors}, active, state) do
    cancel_deadline(active)
    last_error = terminal_errors(terminal_run, errors)
    new_state = %{state | active_run: nil, last_error: last_error}
    dispatch_status(new_state)
    send(self(), :drain)
    send(self(), :refill)
    {:noreply, new_state}
  end

  defp handle_runner_result({:error, reason, run}, active, state) do
    cancel_deadline(active)
    error = Execution.bounded_error(reason)

    degraded = %{
      active
      | run: run || active.run,
        task_pid: nil,
        task_ref: nil,
        deadline_ref: nil,
        phase: :degraded,
        degraded: true,
        error: error
    }

    new_state = %{state | active_run: degraded, last_error: error}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_runner_down(_pid, _reason, %{active_run: %{cancelling: true} = active} = state) do
    active = %{active | task_pid: nil, task_ref: nil, phase: :cancelling}
    {:noreply, %{state | active_run: active}}
  end

  defp handle_runner_down(_pid, reason, %{active_run: active} = state) do
    error = "run task exited: #{Execution.bounded_error(reason)}"

    case start_finalizer(state, active.run, {:error, error}) do
      {:ok, task_pid, task_ref} ->
        active = %{active | task_pid: task_pid, task_ref: task_ref, phase: :finalizing}
        {:noreply, %{state | active_run: active}}

      {:error, start_reason} ->
        error = Execution.bounded_error({:finalizer_task_start_failed, start_reason})

        active = %{
          active
          | task_pid: nil,
            task_ref: nil,
            phase: :degraded,
            degraded: true,
            error: error
        }

        new_state = %{state | active_run: active, last_error: error}
        dispatch_status(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_operation_down(ref, reason, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{type: :submit} = op, pending} ->
        state = %{state | pending: pending}
        {:noreply, start_submit_reconcile(state, op, reason)}

      {%{from: from} = op, pending} ->
        error = Execution.bounded_error({:operation_task_exit, reason})
        GenServer.reply(from, {:error, error})

        state =
          %{state | pending: pending}
          |> Map.update!(:cancelling_ids, &MapSet.delete(&1, Map.get(op, :run_id)))
          |> maybe_reset_cancelling(op)
          |> put_error(error)

        {:noreply, state}

      {%{type: :recovery}, pending} ->
        state = %{state | pending: pending}
        {:noreply, schedule_recovery_retry(state, {:recovery_task_exit, reason})}

      {%{type: :refill}, pending} ->
        state = %{state | pending: pending}
        {:noreply, schedule_refill_retry(state, {:refill_task_exit, reason})}

      {%{type: :timeout}, pending} ->
        state = %{state | pending: pending}
        Process.send_after(self(), {:run_deadline, state.active_run.run.id}, 25)
        {:noreply, put_error(state, {:timeout_task_exit, reason})}
    end
  end

  defp start_operation(state, op, fun) do
    daemon = self()

    case Execution.start_monitored_task(state.task_supervisor, fn ->
           result = Execution.protect(fun)
           send(daemon, {:operation_result, self(), result})
         end) do
      {:ok, pid, ref} ->
        {:ok, %{state | pending: Map.put(state.pending, ref, Map.put(op, :pid, pid))}}

      {:error, reason} ->
        {:error, {:task_start_failed, Execution.bounded_error(reason)}}
    end
  end

  defp start_runner(state, run) do
    daemon = self()

    with {:ok, pid, ref} <-
           Execution.start_monitored_task(state.task_supervisor, fn ->
             Execution.run(daemon, state.deps, run, state.run_timeout)
           end) do
      {:ok, pid, ref}
    end
  end

  defp start_finalizer(state, run, result) do
    daemon = self()

    with {:ok, pid, ref} <-
           Execution.start_monitored_task(state.task_supervisor, fn ->
             terminal =
               case Execution.protect(fn -> Execution.finalize(state.deps, run, result) end) do
                 {:error, reason} -> {:error, reason, run}
                 terminal -> terminal
               end

             send(daemon, {:runner_result, self(), run.id, terminal})
           end) do
      {:ok, pid, ref}
    end
  end

  defp dispatch_status(state) do
    status = Execution.status(state)
    _ = Execution.start_task(state.task_supervisor, fn -> Execution.publish_status(status) end)
    :ok
  end

  defp locate_run(state, run_id) do
    cond do
      state.active_run && state.active_run.run.id == run_id -> {:active, state.active_run}
      run = Enum.find(:queue.to_list(state.queue), &(&1.id == run_id)) -> {:queued, run}
      true -> :unknown
    end
  end

  defp pop_operation(state, pid) do
    case Enum.find(state.pending, fn {_ref, op} -> op.pid == pid end) do
      {ref, op} ->
        Process.demonitor(ref, [:flush])
        {:ok, op, %{state | pending: Map.delete(state.pending, ref)}}

      nil ->
        :error
    end
  end

  defp maybe_reset_cancelling(state, %{type: :cancel, location: :active, run_id: id}) do
    case state.active_run do
      %{run: %{id: ^id}} = active -> %{state | active_run: %{active | cancelling: false}}
      _other -> state
    end
  end

  defp maybe_reset_cancelling(state, _op), do: state

  defp remove_queued(queue, run_id) do
    queue |> :queue.to_list() |> Enum.reject(&(&1.id == run_id)) |> :queue.from_list()
  end

  defp flush_submit_outcomes(state) do
    case Map.pop(state.submit_outcomes, state.next_submit_reply_seq) do
      {nil, _outcomes} ->
        {state, false}

      {{op, result}, outcomes} ->
        GenServer.reply(op.from, result)

        state = %{
          state
          | submit_outcomes: outcomes,
            next_submit_reply_seq: state.next_submit_reply_seq + 1
        }

        state =
          case result do
            {:ok, run} -> %{state | queue: :queue.in(run, state.queue)}
            {:error, reason} -> put_error(state, reason)
          end

        {state, _processed?} = flush_submit_outcomes(state)
        {state, true}
    end
  end

  defp start_submit_reconcile(state, op, reason) do
    reconcile_op = %{op | type: :submit_reconcile}

    case start_operation(state, reconcile_op, fn ->
           Execution.reconcile_submit(state.deps, op.run_id)
         end) do
      {:ok, state} ->
        state

      {:error, start_reason} ->
        retries = Map.put(state.reconcile_retries, op.seq, {op, reason})
        Process.send_after(self(), {:retry_submit_reconcile, op.seq}, 50)
        %{state | reconcile_retries: retries} |> put_error(start_reason)
    end
  end

  defp pending_type?(state, type),
    do: Enum.any?(state.pending, fn {_ref, op} -> op.type == type end)

  defp owned_run_ids(state) do
    ids = Enum.map(:queue.to_list(state.queue), & &1.id)
    ids = if state.active_run, do: [state.active_run.run.id | ids], else: ids

    pending_ids =
      for {_ref, %{type: type, run_id: id}} <- state.pending,
          type in [:submit, :submit_reconcile],
          do: id

    outcome_ids = for {_seq, {op, _result}} <- state.submit_outcomes, do: op.run_id
    retry_ids = for {_seq, {op, _reason}} <- state.reconcile_retries, do: op.run_id
    MapSet.new(ids ++ pending_ids ++ outcome_ids ++ retry_ids)
  end

  defp queue_load(state) do
    reserved =
      Enum.reduce(state.pending, 0, fn {_ref, op}, total ->
        cond do
          op.type in [:submit, :submit_reconcile] -> total + 1
          op.type == :refill -> total + op.reserved_slots
          true -> total
        end
      end)

    :queue.len(state.queue) + reserved + map_size(state.submit_outcomes) +
      map_size(state.reconcile_retries)
  end

  defp cancel_deadline(nil), do: :ok

  defp cancel_deadline(%{deadline_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_deadline(_active), do: :ok

  defp terminal_errors(run, errors) do
    base = if run.status == "failed", do: [run.error], else: []
    join_errors(base ++ errors)
  end

  defp schedule_recovery_retry(state, errors) do
    error = join_errors(List.wrap(errors)) || Execution.bounded_error(errors)
    Process.send_after(self(), :recover, state.recovery_retry_ms)
    new_state = %{state | ready: false, recovery_error: error, last_error: error}
    dispatch_status(new_state)
    new_state
  end

  defp schedule_refill_retry(state, errors) do
    error = join_errors(List.wrap(errors)) || Execution.bounded_error(errors)
    Process.send_after(self(), :refill, state.recovery_retry_ms)
    new_state = %{state | ready: false, recovery_error: error, last_error: error}
    dispatch_status(new_state)
    new_state
  end

  defp put_error(state, reason), do: %{state | last_error: Execution.bounded_error(reason)}

  defp join_errors([]), do: nil
  defp join_errors(errors), do: Execution.bounded_error({:recovery_partial_failure, errors})
end
