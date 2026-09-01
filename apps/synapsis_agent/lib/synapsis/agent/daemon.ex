defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanently supervised FIFO coordinator for durable manual agent runs.

  The GenServer owns only queue and monitor state. Store, event, PubSub, and
  session work runs in supervised tasks under `RunTaskSupervisor`.

  Runs default to a 30-minute absolute timeout. Cleanup and lifecycle event
  effects default to one second; other durable operations default to five seconds.
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
  @cleanup_timeout 1_000
  @event_timeout 1_000
  @operation_timeout 5_000
  @submit_retry_ms 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def topic, do: @topic
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) do
    with {:ok, attrs} <- Execution.manual_attrs(prompt, opts) do
      GenServer.call(server, {:submit, attrs}, :infinity)
    end
  end

  def cancel(run_id), do: cancel(__MODULE__, run_id)

  def cancel(server, run_id) when is_binary(run_id),
    do: GenServer.call(server, {:cancel, run_id}, :infinity)

  def cancel(_server, _run_id), do: {:error, :invalid_run_id}

  @impl true
  def init(opts) do
    config = Application.get_env(:synapsis_agent, __MODULE__, [])
    recover? = Keyword.get(opts, :recover?, true)

    with {:ok, run_timeout} <- timeout_option(opts, :run_timeout, @run_timeout),
         {:ok, cleanup_timeout} <- timeout_option(opts, :cleanup_timeout, @cleanup_timeout),
         {:ok, event_timeout} <- timeout_option(opts, :event_timeout, @event_timeout),
         {:ok, operation_timeout} <-
           timeout_option(opts, :operation_timeout, @operation_timeout) do
      state = %{
        ready: not recover?,
        active_run: nil,
        queue: :queue.new(),
        submit_queue: :queue.new(),
        submit_task: nil,
        status_publisher: nil,
        status_dirty: nil,
        status_sequence: 0,
        cancelling_ids: MapSet.new(),
        pending: %{},
        recovery_backlog_count: 0,
        recovery_retry_ms: Keyword.get(opts, :recovery_retry_ms, 100),
        queue_capacity:
          opts
          |> Keyword.get(:queue_capacity, Keyword.get(config, :queue_capacity, @queue_capacity))
          |> Execution.valid_capacity(@queue_capacity),
        task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
        run_timeout: run_timeout,
        cleanup_timeout: cleanup_timeout,
        event_timeout: event_timeout,
        operation_timeout: operation_timeout,
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
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Execution.status(state), state}

  def handle_call({:submit, attrs}, from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      state.recovery_backlog_count > 0 ->
        {:reply, {:error, :queue_full}, state}

      queue_load(state) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, state}

      true ->
        run_id = Ecto.UUID.generate()
        entry = %{from: from, run_id: run_id, attrs: Map.put(attrs, :id, run_id), mode: :create}
        state = %{state | submit_queue: :queue.in(entry, state.submit_queue)}
        {:noreply, start_submit_head(state)}
    end
  end

  def handle_call({:cancel, run_id}, from, state) do
    case locate_run(state, run_id) do
      {:active, active} when active.cancelling ->
        {:reply, {:error, :cancellation_in_progress}, state}

      {:active, active} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :active}

        case start_operation(state, op, fn ->
               Execution.cancel_active(
                 state.deps,
                 state.task_supervisor,
                 active,
                 state.cleanup_timeout,
                 state.event_timeout
               )
             end) do
          {:ok, state} ->
            active = %{active | cancelling: true, phase: :cancelling}
            {:noreply, %{state | active_run: active}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      {:queued, run} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :queued}

        case start_operation(state, op, fn ->
               Execution.cancel_queued(
                 state.deps,
                 state.task_supervisor,
                 state.event_timeout,
                 run
               )
             end) do
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
    if pending_type?(state, :recovery) do
      {:noreply, state}
    else
      case start_operation(state, %{type: :recovery}, fn ->
             Recovery.run(
               state.deps,
               state.queue_capacity,
               state.task_supervisor,
               state.event_timeout
             )
           end) do
        {:ok, state} -> {:noreply, state}
        {:error, reason} -> {:noreply, schedule_recovery_retry(state, reason)}
      end
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

              active = %{
                run: run,
                task_pid: task_pid,
                task_ref: task_ref,
                inner_pid: nil,
                session_id: nil,
                finalize_intent: nil,
                operation_timer_ref: nil,
                phase: :starting,
                cancelling: false,
                degraded: false,
                error: nil
              }

              state = %{state | queue: queue, active_run: active}
              send(self(), :refill)
              {:noreply, state}

            {:error, reason} ->
              Process.send_after(self(), :drain, 100)
              state = put_error(state, {:run_task_start_failed, reason})
              dispatch_status(state)
              {:noreply, state}
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
        op = %{type: :refill, reserved_slots: available}
        excluded = owned_run_ids(state)

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

  def handle_info({:status_snapshot, status}, state) do
    sequence = state.status_sequence + 1
    snapshot = {sequence, status}
    state = %{state | status_sequence: sequence}

    case state.status_publisher do
      nil -> {:noreply, start_status_publisher(state, snapshot)}
      _publisher -> {:noreply, %{state | status_dirty: snapshot}}
    end
  end

  def handle_info({:retry_status, snapshot}, state) do
    case state.status_publisher do
      nil -> {:noreply, start_status_publisher(state, state.status_dirty || snapshot)}
      _publisher -> {:noreply, %{state | status_dirty: state.status_dirty || snapshot}}
    end
  end

  def handle_info({:status_publish_timeout, ref, pid}, state) do
    case state.status_publisher do
      %{ref: ^ref, pid: ^pid} ->
        Process.exit(pid, :kill)
        state = put_error(state, {:operation_timeout, :status_publish})
        sequence = state.status_sequence + 1
        snapshot = {sequence, Execution.status(state)}
        {:noreply, %{state | status_sequence: sequence, status_dirty: snapshot}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:status_publish_result, pid, sequence, result}, state) do
    case state.status_publisher do
      %{pid: ^pid, ref: ref, timer_ref: timer_ref, sequence: ^sequence} = publisher ->
        Process.demonitor(ref, [:flush])
        cancel_timer(timer_ref)
        state = %{state | status_publisher: nil}

        snapshot =
          case result do
            :ok -> state.status_dirty
            {:ok, _value} -> state.status_dirty
            _error -> state.status_dirty || publisher.snapshot
          end

        state = %{state | status_dirty: nil}
        {:noreply, maybe_start_status_publisher(state, snapshot)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_submit, run_id}, state) do
    case submit_head(state) do
      %{run_id: ^run_id} -> {:noreply, start_submit_head(state)}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:retry_operation, op}, state) do
    case start_operation(state, op, op.fun) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Process.send_after(self(), {:retry_operation, op}, @submit_retry_ms)
        {:noreply, put_error(state, reason)}
    end
  end

  def handle_info({:submit_operation_timeout, ref, pid, run_id}, state) do
    case state.submit_task do
      %{ref: ^ref, pid: ^pid, run_id: ^run_id} ->
        Process.exit(pid, :kill)
        state = put_error(state, {:operation_timeout, :submit, run_id})
        dispatch_status(state)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:operation_timeout, ref, pid}, state) do
    case Map.get(state.pending, ref) do
      %{pid: ^pid} = op ->
        Process.exit(pid, :kill)
        state = put_error(state, {:operation_timeout, op.type})
        dispatch_status(state)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:runner_inner, task_pid, run_id, inner_pid},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    state = %{state | active_run: %{active | inner_pid: inner_pid}}
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:runner_inner, _task_pid, _run_id, _inner_pid}, state), do: {:noreply, state}

  def handle_info(
        {:session_created, task_pid, run_id, session_id},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    state = %{state | active_run: %{active | session_id: session_id}}
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:session_created, _task_pid, _run_id, _session_id}, state),
    do: {:noreply, state}

  def handle_info(
        {:runner_started, task_pid, %AgentRun{} = run, event_errors},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      )
      when run.id == run_id do
    state = %{
      state
      | active_run: %{active | run: run, phase: :running},
        last_error: join_errors(event_errors) || state.last_error
    }

    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:runner_started, _task_pid, _run, _event_errors}, state),
    do: {:noreply, state}

  def handle_info(
        {:runner_finalizing, task_pid, run_id, run, outcome, session_id, warnings},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    cancel_timer(active.operation_timer_ref)

    timer_ref =
      Process.send_after(
        self(),
        {:runner_operation_timeout, active.task_ref, task_pid, run_id},
        state.operation_timeout
      )

    intent = %{run: run, outcome: outcome, session_id: session_id, warnings: warnings}

    active = %{
      active
      | run: run,
        session_id: session_id || active.session_id,
        finalize_intent: intent,
        operation_timer_ref: timer_ref,
        phase: :finalizing
    }

    send(task_pid, {:runner_finalizing_ack, run_id})
    state = %{state | active_run: active}
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info(
        {:runner_finalizing, _task_pid, _run_id, _run, _outcome, _session_id, _warnings},
        state
      ),
      do: {:noreply, state}

  def handle_info({:runner_operation_timeout, ref, pid, run_id}, state) do
    case state.active_run do
      %{task_ref: ^ref, task_pid: ^pid, run: %{id: ^run_id}, phase: :finalizing} ->
        Process.exit(pid, :kill)
        state = put_error(state, {:operation_timeout, :finalize, run_id})
        dispatch_status(state)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:submit_result, task_pid, run_id, result}, state) do
    case state.submit_task do
      %{pid: ^task_pid, ref: ref, run_id: ^run_id} ->
        Process.demonitor(ref, [:flush])
        cancel_timer(state.submit_task.timer_ref)
        handle_submit_result(result, %{state | submit_task: nil})

      _other ->
        {:noreply, state}
    end
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
    cancel_timer(active.operation_timer_ref)
    Process.demonitor(active.task_ref, [:flush])
    handle_runner_result(result, active, state)
  end

  def handle_info({:runner_result, _task_pid, _run_id, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      state.submit_task && state.submit_task.ref == ref ->
        handle_submit_down(reason, state)

      state.active_run && state.active_run.task_ref == ref ->
        handle_runner_down(pid, reason, state)

      state.status_publisher && state.status_publisher.ref == ref ->
        handle_status_publisher_down(reason, state)

      true ->
        handle_operation_down(ref, reason, state)
    end
  end

  defp handle_submit_result({:ok, run, errors}, state) do
    {entry, state} = pop_submit_head(state)
    GenServer.reply(entry.from, {:ok, run})
    state = %{state | queue: :queue.in(run, state.queue), last_error: join_errors(errors)}
    dispatch_status(state)
    send(self(), :drain)
    {:noreply, start_submit_head(state)}
  end

  defp handle_submit_result({:error, reason}, state) do
    {entry, state} = pop_submit_head(state)
    GenServer.reply(entry.from, {:error, reason})
    state = put_error(state, reason)
    dispatch_status(state)
    {:noreply, start_submit_head(state)}
  end

  defp handle_submit_result({:retry, reason}, state) do
    entry = submit_head(state)
    Process.send_after(self(), {:retry_submit, entry.run_id}, @submit_retry_ms)
    state = state |> set_submit_head_mode(:reconcile) |> put_error(reason)
    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_operation_result(
         %{type: :cancel, from: from, run_id: id, location: location},
         {:ok, terminal, errors},
         state
       ) do
    GenServer.reply(from, {:ok, terminal})

    state =
      state
      |> clear_cancelled_owner(location, id)
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, id))
      |> Map.put(:last_error, join_errors(errors))

    dispatch_status(state)
    send(self(), :drain)
    send(self(), :refill)
    {:noreply, state}
  end

  defp handle_operation_result(
         %{type: :cancel, from: from, run_id: id, location: :active},
         {:degraded, reason, run, errors},
         state
       ) do
    GenServer.reply(from, {:error, reason})
    error = join_errors([reason | errors])

    state =
      case state.active_run do
        %{run: %{id: ^id}} = active ->
          degraded = %{
            active
            | run: run || active.run,
              task_pid: nil,
              task_ref: nil,
              inner_pid: nil,
              phase: :degraded,
              degraded: true,
              cancelling: false,
              error: error
          }

          %{state | active_run: degraded}

        _other ->
          state
      end

    state = %{
      state
      | cancelling_ids: MapSet.delete(state.cancelling_ids, id),
        last_error: error
    }

    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_operation_result(%{type: :cancel, from: from} = op, {:error, reason}, state) do
    GenServer.reply(from, {:error, reason})

    state =
      state
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, op.run_id))
      |> maybe_reset_cancelling(op)
      |> put_error(reason)

    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_operation_result(
         %{type: :recovery},
         {:ok, queued, backlog, event_errors},
         state
       ) do
    state = %{
      state
      | ready: true,
        queue: :queue.from_list(queued),
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: join_errors(event_errors)
    }

    dispatch_status(state)
    send(self(), :drain)
    {:noreply, state}
  end

  defp handle_operation_result(%{type: :recovery}, {:retry, errors}, state),
    do: {:noreply, schedule_recovery_retry(state, errors)}

  defp handle_operation_result(%{type: :recovery}, {:error, reason}, state),
    do: {:noreply, schedule_recovery_retry(state, reason)}

  defp handle_operation_result(%{type: :refill}, {:ok, queued, backlog}, state) do
    queue = Enum.reduce(queued, state.queue, &:queue.in/2)

    state = %{
      state
      | ready: true,
        queue: queue,
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: nil
    }

    dispatch_status(state)
    send(self(), :drain)
    {:noreply, state}
  end

  defp handle_operation_result(%{type: :refill}, {:retry, errors}, state),
    do: {:noreply, schedule_refill_retry(state, errors)}

  defp handle_operation_result(%{type: :refill}, {:error, reason}, state),
    do: {:noreply, schedule_refill_retry(state, reason)}

  defp handle_runner_result({:ok, terminal_run, errors}, _active, state) do
    state = %{
      state
      | active_run: nil,
        last_error: terminal_errors(terminal_run, errors)
    }

    dispatch_status(state)
    send(self(), :drain)
    send(self(), :refill)
    {:noreply, state}
  end

  defp handle_runner_result({:error, reason, run}, active, state) do
    error = Execution.bounded_error(reason)

    degraded = %{
      active
      | run: run || active.run,
        task_pid: nil,
        task_ref: nil,
        inner_pid: nil,
        operation_timer_ref: nil,
        phase: :degraded,
        degraded: true,
        error: error
    }

    state = %{state | active_run: degraded, last_error: error}
    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_submit_down(reason, state) do
    entry = submit_head(state)
    cancel_timer(state.submit_task.timer_ref)
    Process.send_after(self(), {:retry_submit, entry.run_id}, @submit_retry_ms)

    state =
      %{state | submit_task: nil}
      |> set_submit_head_mode(:reconcile)
      |> put_error({:submit_task_exit, reason})

    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_runner_down(_pid, _reason, %{active_run: %{cancelling: true} = active} = state) do
    cancel_timer(active.operation_timer_ref)

    active = %{
      active
      | task_pid: nil,
        task_ref: nil,
        inner_pid: nil,
        operation_timer_ref: nil,
        phase: :cancelling
    }

    {:noreply, %{state | active_run: active}}
  end

  defp handle_runner_down(_pid, reason, %{active_run: active} = state) do
    cancel_timer(active.operation_timer_ref)

    start_result =
      case active.finalize_intent do
        nil -> start_finalizer(state, active, reason)
        intent -> start_intent_finalizer(state, active, intent)
      end

    case start_result do
      {:ok, task_pid, task_ref} ->
        timer_ref =
          Process.send_after(
            self(),
            {:runner_operation_timeout, task_ref, task_pid, active.run.id},
            state.operation_timeout
          )

        active = %{
          active
          | task_pid: task_pid,
            task_ref: task_ref,
            inner_pid: nil,
            operation_timer_ref: timer_ref,
            phase: :finalizing
        }

        {:noreply, %{state | active_run: active}}

      {:error, start_reason} ->
        error = Execution.bounded_error({:finalizer_task_start_failed, start_reason})

        active = %{
          active
          | task_pid: nil,
            task_ref: nil,
            inner_pid: nil,
            operation_timer_ref: nil,
            phase: :degraded,
            degraded: true,
            error: error
        }

        state = %{state | active_run: active, last_error: error}
        dispatch_status(state)
        {:noreply, state}
    end
  end

  defp handle_operation_down(ref, reason, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{type: :recovery, timer_ref: timer_ref}, pending} ->
        cancel_timer(timer_ref)
        state = %{state | pending: pending}
        {:noreply, schedule_recovery_retry(state, {:recovery_task_exit, reason})}

      {%{type: :refill, timer_ref: timer_ref}, pending} ->
        cancel_timer(timer_ref)
        state = %{state | pending: pending}
        {:noreply, schedule_refill_retry(state, {:refill_task_exit, reason})}

      {op, pending} ->
        cancel_timer(op.timer_ref)
        retry_op = Map.drop(op, [:pid, :timer_ref])
        Process.send_after(self(), {:retry_operation, retry_op}, @submit_retry_ms)

        state =
          %{state | pending: pending}
          |> put_error({:operation_task_exit, reason})

        dispatch_status(state)
        {:noreply, state}
    end
  end

  defp start_submit_head(%{submit_task: nil} = state) do
    case submit_head(state) do
      nil ->
        state

      entry ->
        daemon = self()

        case Execution.start_monitored_task(state.task_supervisor, fn ->
               result =
                 Execution.persist_submission(
                   state.deps,
                   entry.attrs,
                   entry.mode,
                   state.task_supervisor,
                   state.event_timeout
                 )

               send(daemon, {:submit_result, self(), entry.run_id, result})
             end) do
          {:ok, pid, ref} ->
            timer_ref =
              Process.send_after(
                self(),
                {:submit_operation_timeout, ref, pid, entry.run_id},
                state.operation_timeout
              )

            %{
              state
              | submit_task: %{pid: pid, ref: ref, run_id: entry.run_id, timer_ref: timer_ref}
            }

          {:error, reason} ->
            Process.send_after(self(), {:retry_submit, entry.run_id}, @submit_retry_ms)

            state
            |> set_submit_head_mode(:reconcile)
            |> put_error({:submit_task_start_failed, reason})
        end
    end
  end

  defp start_submit_head(state), do: state

  defp start_operation(state, op, fun) do
    daemon = self()

    case Execution.start_monitored_task(state.task_supervisor, fn ->
           result = Execution.protect(fun)
           send(daemon, {:operation_result, self(), result})
         end) do
      {:ok, pid, ref} ->
        timer_ref =
          Process.send_after(self(), {:operation_timeout, ref, pid}, state.operation_timeout)

        pending_op =
          op
          |> Map.put(:pid, pid)
          |> Map.put(:timer_ref, timer_ref)
          |> Map.put(:fun, fun)

        {:ok, %{state | pending: Map.put(state.pending, ref, pending_op)}}

      {:error, reason} ->
        {:error, {:task_start_failed, Execution.bounded_error(reason)}}
    end
  end

  defp start_runner(state, run) do
    daemon = self()

    Execution.start_monitored_task(state.task_supervisor, fn ->
      Execution.run(
        daemon,
        state.deps,
        state.task_supervisor,
        run,
        state.run_timeout,
        Map.get(state, :cleanup_timeout, @cleanup_timeout),
        Map.get(state, :event_timeout, @event_timeout)
      )
    end)
  end

  defp start_finalizer(state, active, reason) do
    daemon = self()

    Execution.start_monitored_task(state.task_supervisor, fn ->
      result =
        Execution.protect(fn ->
          Execution.finalize_crashed_outer(
            state.deps,
            state.task_supervisor,
            active,
            reason,
            state.cleanup_timeout,
            state.event_timeout
          )
        end)

      result =
        if match?({:error, _reason}, result), do: {:error, result, active.run}, else: result

      send(daemon, {:runner_result, self(), active.run.id, result})
    end)
  end

  defp start_intent_finalizer(state, active, intent) do
    daemon = self()

    Execution.start_monitored_task(state.task_supervisor, fn ->
      result =
        Execution.protect(fn ->
          Execution.finalize_intent(
            state.deps,
            state.task_supervisor,
            state.event_timeout,
            intent
          )
        end)

      result =
        if match?({:error, _reason}, result), do: {:error, result, intent.run}, else: result

      send(daemon, {:runner_result, self(), active.run.id, result})
    end)
  end

  defp dispatch_status(state) do
    status = Execution.status(state)
    send(self(), {:status_snapshot, status})
    :ok
  end

  defp start_status_publisher(state, nil), do: state

  defp start_status_publisher(state, {sequence, status} = snapshot) do
    daemon = self()

    case Execution.start_monitored_task(state.task_supervisor, fn ->
           result =
             Execution.protect(fn ->
               RunEvents.publish_status(state.deps.run_events, status, sequence)
             end)

           send(daemon, {:status_publish_result, self(), sequence, result})
         end) do
      {:ok, pid, ref} ->
        timer_ref =
          Process.send_after(self(), {:status_publish_timeout, ref, pid}, state.event_timeout)

        publisher = %{
          pid: pid,
          ref: ref,
          timer_ref: timer_ref,
          sequence: sequence,
          snapshot: snapshot
        }

        %{state | status_publisher: publisher, status_dirty: nil}

      {:error, reason} ->
        Process.send_after(self(), {:retry_status, snapshot}, @submit_retry_ms)
        put_error(state, {:status_publish_start_failed, reason})
    end
  end

  defp maybe_start_status_publisher(state, nil), do: state
  defp maybe_start_status_publisher(state, snapshot), do: start_status_publisher(state, snapshot)

  defp handle_status_publisher_down(reason, state) do
    publisher = state.status_publisher
    cancel_timer(publisher.timer_ref)
    state = %{state | status_publisher: nil}

    {state, snapshot} =
      case reason do
        :killed ->
          {state, state.status_dirty || publisher.snapshot}

        _other ->
          state = put_error(state, {:status_publish_task_exit, reason})
          sequence = state.status_sequence + 1
          state = %{state | status_sequence: sequence}
          {state, {sequence, Execution.status(state)}}
      end

    Process.send_after(self(), {:retry_status, snapshot}, @submit_retry_ms)
    state = %{state | status_dirty: nil}

    {:noreply, state}
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
        cancel_timer(op.timer_ref)
        {:ok, op, %{state | pending: Map.delete(state.pending, ref)}}

      nil ->
        :error
    end
  end

  defp submit_head(state) do
    case :queue.peek(state.submit_queue) do
      {:value, entry} -> entry
      :empty -> nil
    end
  end

  defp pop_submit_head(state) do
    {{:value, entry}, submit_queue} = :queue.out(state.submit_queue)
    {entry, %{state | submit_queue: submit_queue}}
  end

  defp set_submit_head_mode(state, mode) do
    case :queue.out(state.submit_queue) do
      {{:value, entry}, rest} ->
        %{state | submit_queue: :queue.in_r(%{entry | mode: mode}, rest)}

      {:empty, _queue} ->
        state
    end
  end

  defp clear_cancelled_owner(state, :active, id) do
    case state.active_run do
      %{run: %{id: ^id}} -> %{state | active_run: nil}
      _other -> state
    end
  end

  defp clear_cancelled_owner(state, :queued, id),
    do: %{state | queue: remove_queued(state.queue, id)}

  defp clear_cancelled_owner(state, :unknown, _id), do: state

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

  defp pending_type?(state, type),
    do: Enum.any?(state.pending, fn {_ref, op} -> op.type == type end)

  defp owned_run_ids(state) do
    queued_ids = Enum.map(:queue.to_list(state.queue), & &1.id)
    active_ids = if state.active_run, do: [state.active_run.run.id], else: []
    submit_ids = Enum.map(:queue.to_list(state.submit_queue), & &1.run_id)
    MapSet.new(active_ids ++ queued_ids ++ submit_ids)
  end

  defp queue_load(state) do
    refill_reservations =
      Enum.reduce(state.pending, 0, fn {_ref, op}, total ->
        if op.type == :refill, do: total + op.reserved_slots, else: total
      end)

    :queue.len(state.queue) + :queue.len(state.submit_queue) + refill_reservations
  end

  defp terminal_errors(run, errors) do
    base = if run.status == "failed", do: [run.error], else: []
    join_errors(base ++ errors)
  end

  defp schedule_recovery_retry(state, errors) do
    error = join_errors(List.wrap(errors)) || Execution.bounded_error(errors)
    Process.send_after(self(), :recover, state.recovery_retry_ms)
    state = %{state | ready: false, recovery_error: error, last_error: error}
    dispatch_status(state)
    state
  end

  defp schedule_refill_retry(state, errors) do
    error = join_errors(List.wrap(errors)) || Execution.bounded_error(errors)
    Process.send_after(self(), :refill, state.recovery_retry_ms)
    state = %{state | ready: false, recovery_error: error, last_error: error}
    dispatch_status(state)
    state
  end

  defp put_error(state, reason), do: %{state | last_error: Execution.bounded_error(reason)}

  defp join_errors([]), do: nil
  defp join_errors(errors), do: Execution.bounded_error({:operation_warnings, errors})

  defp timeout_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      timeout when key == :run_timeout and is_integer(timeout) and timeout >= 0 -> {:ok, timeout}
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _invalid -> {:error, {:invalid_timeout, key}}
    end
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: :ok
end
