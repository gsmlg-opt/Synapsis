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
  alias Synapsis.Agent.Daemon.{Execution, Operations, StatusPublisher}
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
  @liveness_interval_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def topic, do: @topic
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) do
    if opts == [] do
      {:error, :invalid_options}
    else
      do_submit(server, prompt, opts)
    end
  end

  defp do_submit(server, prompt, opts) do
    opts = normalize_submit_opts(opts)

    with {:ok, attrs} <- Execution.manual_attrs(prompt, opts) do
      GenServer.call(server, {:submit, attrs}, :infinity)
    end
  end

  def trigger(:heartbeat, routine_id) when is_binary(routine_id), do: {:error, :missing_prompt}

  def trigger(kind, routine_id) when kind in [:dream, :schedule] and is_binary(routine_id),
    do: {:error, :not_implemented}

  def trigger(kind, nil) when is_atom(kind), do: {:error, :invalid_kind}

  def trigger(kind, opts), do: trigger(__MODULE__, kind, opts)

  @doc "Compatibility form used by older heartbeat callers."
  def trigger(kind, routine_id, opts)
      when kind in [:heartbeat, :schedule, :dream] and
             (is_binary(routine_id) or is_nil(routine_id)) do
    opts =
      opts
      |> normalize_trigger_opts()
      |> Map.put_new(:routine_id, routine_id)
      |> maybe_put_heartbeat_id(kind, routine_id)
      |> normalize_legacy_agent()

    trigger(kind, opts)
  end

  def trigger(server, :heartbeat, opts) do
    with {:ok, attrs} <- Execution.heartbeat_attrs(opts) do
      GenServer.call(server, {:submit, attrs}, :infinity)
    end
  end

  def trigger(server, kind, opts) when kind in [:schedule, :dream] do
    with {:ok, attrs} <- Execution.routine_attrs(kind, opts) do
      GenServer.call(server, {:submit, attrs}, :infinity)
    end
  end

  def trigger(_server, _kind, _opts), do: {:error, :unsupported_trigger}

  def cancel(run_id) do
    case cancel(__MODULE__, run_id) do
      {:ok, _run} -> :ok
      other -> other
    end
  end

  def cancel(server, run_id) when is_binary(run_id),
    do: GenServer.call(server, {:cancel, run_id}, :infinity)

  def cancel(_server, _run_id), do: {:error, :invalid_run_id}

  @doc "Register a paused producer with this Daemon before allowing it to submit."
  def register_automation_producer(daemon, scheduler, ref, producer, target)
      when is_pid(daemon) and is_pid(scheduler) and is_reference(ref) and is_pid(producer) do
    send(daemon, {:register_automation_producer, scheduler, ref, producer, target})
    :ok
  end

  @doc "Request cancellation of work captured by this owner's ordered message boundary."
  def request_automation_cancellation(daemon, scheduler, ref, target)
      when is_pid(daemon) and is_pid(scheduler) and is_reference(ref) do
    send(daemon, {:request_automation_cancellation, scheduler, ref, target})
    :ok
  end

  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, :infinity)

  def record_heartbeat_outcome(_routine_id, outcome, _opts \\ [])
      when outcome in [:completed, :failed] do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:heartbeat_outcome, outcome})
    :ok
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:synapsis_agent, __MODULE__, [])
    recover? = Keyword.get(opts, :recover?, true)

    with {:ok, run_timeout} <- timeout_option(opts, :run_timeout, @run_timeout),
         {:ok, cleanup_timeout} <- timeout_option(opts, :cleanup_timeout, @cleanup_timeout),
         {:ok, event_timeout} <- timeout_option(opts, :event_timeout, @event_timeout),
         {:ok, operation_timeout} <-
           timeout_option(opts, :operation_timeout, @operation_timeout),
         {:ok, liveness_interval_ms} <-
           timeout_option(opts, :liveness_interval_ms, @liveness_interval_ms) do
      state = %{
        ready: not recover?,
        active_run: nil,
        queue: :queue.new(),
        submit_queue: :queue.new(),
        submit_task: nil,
        status_publisher: Keyword.get(opts, :status_publisher, StatusPublisher),
        cancelling_ids: MapSet.new(),
        automation_producers: %{},
        automation_cancel_ids: MapSet.new(),
        automation_recovery_targets: MapSet.new(),
        automation_retirement_observers: %{},
        automation_recovery_runs: %{},
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
        liveness_interval_ms: liveness_interval_ms,
        liveness_target:
          Keyword.get(opts, :liveness_target, Synapsis.Agent.Heartbeat.LocalScheduler),
        last_seen_at: DateTime.utc_now(),
        last_heartbeat_success_at: nil,
        heartbeat_failure_streak: 0,
        deps: %{
          runs: Keyword.get(opts, :runs, Runs),
          run_events: Keyword.get(opts, :run_events, RunEvents),
          sessions: Keyword.get(opts, :sessions, Sessions),
          permission: Keyword.get(opts, :permission, Synapsis.Tool.Permission)
        },
        last_error: nil,
        recovery_error: nil
      }

      Process.send_after(self(), :liveness_check, liveness_interval_ms)
      send(self(), if(recover?, do: :recover, else: :status_changed))
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Execution.status(state), state}

  def handle_call({:delivery_snapshot, run_id}, _from, state) do
    snapshot =
      case state.active_run do
        %{run: %{id: ^run_id} = run} -> {:ok, run}
        _ -> :not_found
      end

    {:reply, snapshot, state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, {:ok, Execution.status(state)}, state}
  end

  def handle_call({:submit, attrs}, from, state) do
    {producer, state} = take_automation_producer(state, elem(from, 0))

    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, finish_retirement_identities(state)}

      state.recovery_backlog_count > 0 ->
        {:reply, {:error, :queue_full}, finish_retirement_identities(state)}

      queue_load(state) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, finish_retirement_identities(state)}

      overlapping?(state, attrs) ->
        {:reply, {:error, :overlap}, finish_retirement_identities(state)}

      true ->
        run_id = Ecto.UUID.generate()

        entry = %{
          from: from,
          run_id: run_id,
          attrs: Map.put(attrs, :id, run_id),
          mode: :create,
          automation_retired: (producer && producer.retired) == true,
          retirement_refs: if(producer, do: producer.retirement_refs, else: MapSet.new()),
          dispatched: false
        }

        state = %{state | submit_queue: :queue.in(entry, state.submit_queue)}
        {:noreply, start_submit_head(state)}
    end
  end

  def handle_call({:cancel, run_id}, from, state) do
    case locate_run(state, run_id) do
      {:active, active} when active.cancelling ->
        {:reply, {:error, :cancellation_in_progress}, state}

      {:active, active} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :active, active: active}

        case start_operation(state, op) do
          {:ok, state} ->
            active = %{active | cancelling: true, phase: :cancelling}
            {:noreply, %{state | active_run: active}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      {:queued, run} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :queued, run: run}

        case start_operation(state, op) do
          {:ok, state} ->
            {:noreply, %{state | cancelling_ids: MapSet.put(state.cancelling_ids, run_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      :unknown ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :unknown}

        case start_operation(state, op) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  @impl true
  def handle_cast({:heartbeat_outcome, :failed}, state) do
    {:noreply, %{state | heartbeat_failure_streak: state.heartbeat_failure_streak + 1}}
  end

  def handle_cast({:heartbeat_outcome, :completed}, state) do
    {:noreply,
     %{state | heartbeat_failure_streak: 0, last_heartbeat_success_at: DateTime.utc_now()}}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:register_automation_producer, scheduler, ref, producer, target}, state) do
    {_previous, state} = take_automation_producer(state, producer)
    monitor = Process.monitor(producer)

    registration = %{
      ref: ref,
      monitor: monitor,
      target: target,
      retired: false,
      retirement_refs: MapSet.new()
    }

    state = put_in(state.automation_producers[producer], registration)
    send(producer, {:automation_producer_ready, ref, self()})
    if scheduler != producer, do: send(scheduler, {:automation_producer_ready, ref, self()})
    {:noreply, finish_retirement_identities(state)}
  end

  def handle_info({:request_automation_cancellation, scheduler, ref, target}, state) do
    active =
      if state.active_run && automation_identity(state.active_run.run) == target, do: 1, else: 0

    queued = Enum.count(:queue.to_list(state.queue), &(automation_identity(&1) == target))

    submissions =
      Enum.count(:queue.to_list(state.submit_queue), &(automation_identity(&1.attrs) == target))

    producers =
      Enum.count(state.automation_producers, fn {_pid, item} -> item.target == target end)

    recovery = if not state.ready or pending_type?(state, :recovery), do: 1, else: 0
    refill = if state.recovery_backlog_count > 0 or pending_type?(state, :refill), do: 1, else: 0

    known_ids = captured_retirement_ids(state, target)

    state = %{
      state
      | automation_producers:
          Map.new(state.automation_producers, fn {pid, item} ->
            {pid,
             if(item.target == target,
               do: %{item | retired: true, retirement_refs: MapSet.put(item.retirement_refs, ref)},
               else: item
             )}
          end),
        submit_queue:
          state.submit_queue
          |> :queue.to_list()
          |> Enum.map(fn entry ->
            if automation_identity(entry.attrs) == target,
              do: %{
                entry
                | automation_retired: true,
                  retirement_refs: MapSet.put(entry.retirement_refs, ref)
              },
              else: entry
          end)
          |> :queue.from_list(),
        automation_recovery_targets:
          if(recovery + refill > 0,
            do: MapSet.put(state.automation_recovery_targets, target),
            else: state.automation_recovery_targets
          )
    }

    observer = %{scheduler: scheduler, target: target, recovery: recovery + refill > 0}
    state = put_in(state.automation_retirement_observers[ref], observer)
    state = request_matching_cancellations(state, target)
    identity_complete = retirement_identity_complete?(state, ref, observer)

    observation = %{
      status: :cancellation_requested,
      target: target,
      retired_run_ids: known_ids,
      identity_complete: identity_complete,
      active_count: active,
      queued_count: queued,
      submission_count: submissions,
      producer_count: producers,
      pending_recovery_count: recovery,
      pending_refill_count: refill,
      cleanup_pending: active + queued + submissions + producers + recovery + refill > 0
    }

    send(scheduler, {:automation_cancellation_requested, ref, observation})

    state =
      if identity_complete,
        do: %{
          state
          | automation_retirement_observers:
              Map.delete(state.automation_retirement_observers, ref)
        },
        else: state

    {:noreply, state}
  end

  def handle_info({:automation_recovery_observed, task_pid, runs}, state) do
    if Enum.any?(state.pending, fn {_ref, op} ->
         op.pid == task_pid and op.type in [:recovery, :refill]
       end) do
      identities =
        Enum.reduce(runs, state.automation_recovery_runs, fn run, found ->
          case automation_identity(run) do
            nil -> found
            target -> Map.put(found, run.id, target)
          end
        end)

      state = %{state | automation_recovery_runs: identities}

      Enum.each(state.automation_retirement_observers, fn {ref, observer} ->
        if observer.recovery do
          ids = for run <- runs, automation_identity(run) == observer.target, do: run.id
          notify_retirement_ids(ref, observer, ids)
        end
      end)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:recover, state) do
    if pending_type?(state, :recovery) do
      {:noreply, state}
    else
      case start_operation(state, %{type: :recovery, capacity: state.queue_capacity}) do
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
                delivery_intent: nil,
                delivery_pid: nil,
                daemon_pid: self(),
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
        excluded = owned_run_ids(state)

        op = %{
          type: :refill,
          reserved_slots: available,
          excluded: excluded,
          limit: available
        }

        case start_operation(state, op) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:noreply, schedule_refill_retry(state, reason)}
        end
    end
  end

  def handle_info(:status_changed, state) do
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info(:liveness_check, state) do
    state = %{state | last_seen_at: DateTime.utc_now()}
    request_due_routine_check(state.liveness_target)
    send(self(), :drain)
    send(self(), :refill)
    Process.send_after(self(), :liveness_check, state.liveness_interval_ms)
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:retry_submit, run_id}, state) do
    case submit_head(state) do
      %{run_id: ^run_id} -> {:noreply, start_submit_head(state)}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:retry_operation, op}, state) do
    case start_operation(state, op) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Process.send_after(self(), {:retry_operation, op}, @submit_retry_ms)
        {:noreply, put_error(state, reason)}
    end
  end

  def handle_info({:retry_automation_cancel, id}, state) do
    if MapSet.member?(state.automation_cancel_ids, id) do
      state = %{state | cancelling_ids: MapSet.delete(state.cancelling_ids, id)}

      state =
        case locate_run(state, id) do
          {:active, active} -> request_active_cancellation(state, active)
          {:queued, run} -> request_queued_cancellation(state, run)
          :unknown -> state
        end

      {:noreply, state}
    else
      {:noreply, state}
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
        {:runner_delivering, task_pid, run_id, stage_ref, run, outcome, session_id, warnings},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}, cancelling: false} = active} =
          state
      ) do
    intent = %{
      run: run,
      outcome: outcome,
      session_id: session_id,
      warnings: warnings,
      stage_ref: stage_ref
    }

    active = %{
      active
      | run: run,
        session_id: session_id || active.session_id,
        delivery_intent: intent,
        phase: :delivering
    }

    send(task_pid, {:runner_delivery_ack, stage_ref, :ok})
    state = %{state | active_run: active}
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info({:runner_delivering, pid, _id, ref, _run, _outcome, _session, _warnings}, state) do
    send(pid, {:runner_delivery_ack, ref, :rejected})
    {:noreply, state}
  end

  def handle_info(
        {:runner_delivery_child, task_pid, run_id, stage_ref, child, acknowledgement},
        %{
          active_run:
            %{
              task_pid: task_pid,
              run: %{id: run_id},
              cancelling: false,
              delivery_intent: %{stage_ref: stage_ref}
            } = active
        } = state
      ) do
    send(task_pid, {:runner_delivery_ack, acknowledgement, :ok})
    {:noreply, %{state | active_run: %{active | delivery_pid: child}}}
  end

  def handle_info({:runner_delivery_child, pid, _id, _stage, _child, ref}, state) do
    send(pid, {:runner_delivery_ack, ref, :rejected})
    {:noreply, state}
  end

  def handle_info(
        {:runner_delivery_progress, task_pid, run_id, stage_ref, child, acknowledgement, run},
        %{
          active_run:
            %{
              task_pid: task_pid,
              run: %{id: run_id},
              delivery_pid: child,
              delivery_intent: %{stage_ref: stage_ref} = intent
            } = active
        } = state
      ) do
    # Retain a received response during cancellation, but never grant a new dispatch.
    rejected? = active.cancelling and run.metadata["automation_delivery"]["status"] == "unknown"

    run =
      if rejected?,
        do:
          Synapsis.Agent.Automation.Execution.settle_webhook(run, intent.outcome, %{
            "status" => "not-delivered",
            "delivered" => false,
            "attempted" => false,
            "attempt_count" => 0,
            "error" => "webhook_cancelled"
          }),
        else: run

    active = %{active | run: run, delivery_intent: %{intent | run: run}}

    send(
      task_pid,
      {:runner_delivery_ack, acknowledgement, if(rejected?, do: :rejected, else: :ok)}
    )

    {:noreply, %{state | active_run: active}}
  end

  def handle_info({:runner_delivery_progress, pid, _id, _stage, _child, ref, _run}, state) do
    send(pid, {:runner_delivery_ack, ref, :rejected})
    {:noreply, state}
  end

  def handle_info(
        {:runner_finalizing, task_pid, run_id, run, outcome, session_id, warnings},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}, cancelling: false} = active} =
          state
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
        {:runner_finalizing, task_pid, run_id, _run, _outcome, _session_id, _warnings},
        state
      ) do
    send(task_pid, {:runner_finalizing_rejected, run_id})
    {:noreply, state}
  end

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
      match?(%{monitor: ^ref}, Map.get(state.automation_producers, pid)) ->
        {_producer, state} = take_automation_producer(state, pid)
        {:noreply, finish_retirement_identities(state)}

      state.submit_task && state.submit_task.ref == ref ->
        handle_submit_down(reason, state)

      state.active_run && state.active_run.task_ref == ref ->
        handle_runner_down(pid, reason, state)

      true ->
        handle_operation_down(ref, reason, state)
    end
  end

  defp handle_submit_result({:ok, run, errors}, state) do
    {entry, state} = pop_submit_head(state)
    state = notify_submission_retirement(state, entry, run.id)
    GenServer.reply(entry.from, {:ok, run})

    retired = entry.automation_retired || MapSet.member?(state.automation_cancel_ids, run.id)

    queue =
      if run.status == "queued" and not Enum.any?(owned_runs(state), &(&1.id == run.id)),
        do: :queue.in(run, state.queue),
        else: state.queue

    state = %{state | queue: queue, last_error: join_errors(errors)}

    state =
      if retired and run.status == "queued",
        do: request_queued_cancellation(state, run),
        else: state

    dispatch_status(state)
    send(self(), :drain)
    {:noreply, state |> finish_retirement_identities() |> start_submit_head()}
  end

  defp handle_submit_result({:error, reason}, state) do
    {entry, state} = pop_submit_head(state)
    GenServer.reply(entry.from, {:error, reason})
    state = put_error(state, reason) |> finish_retirement_identities()
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
    reply_cancel(from, {:ok, terminal})

    state =
      state
      |> clear_cancelled_owner(location, id)
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, id))
      |> Map.put(:last_error, join_errors(errors))
      |> finish_automation_cancellation(id)

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
    reply_cancel(from, {:error, reason})
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

    state = retry_managed_cancellation(state, id)

    dispatch_status(state)
    {:noreply, state}
  end

  defp handle_operation_result(%{type: :cancel, from: from} = op, {:error, reason}, state) do
    reply_cancel(from, {:error, reason})

    state =
      state
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, op.run_id))
      |> maybe_reset_cancelling(op)
      |> put_error(reason)

    state = retry_managed_cancellation(state, op.run_id)

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
        queue: merge_recovered_queue(state, queued),
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: join_errors(event_errors)
    }

    state = apply_recovery_cancellations(state)

    dispatch_status(state)
    send(self(), :drain)
    {:noreply, state}
  end

  defp handle_operation_result(%{type: :recovery}, {:retry, errors}, state),
    do: {:noreply, schedule_recovery_retry(state, errors)}

  defp handle_operation_result(%{type: :recovery}, {:error, reason}, state),
    do: {:noreply, schedule_recovery_retry(state, reason)}

  defp handle_operation_result(%{type: :refill}, {:ok, queued, backlog}, state) do
    queue = merge_recovered_queue(state, queued)

    state = %{
      state
      | ready: true,
        queue: queue,
        recovery_backlog_count: backlog,
        recovery_error: nil,
        last_error: nil
    }

    state = apply_recovery_cancellations(state)

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
      case active.finalize_intent || delivery_finalization_intent(active) do
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

  defp delivery_finalization_intent(%{delivery_intent: intent}) when is_map(intent) do
    run = Synapsis.Agent.Automation.Execution.interrupted_webhook(intent.run)
    %{intent | run: run}
  end

  defp delivery_finalization_intent(_active), do: nil

  defp handle_operation_down(ref, reason, state) do
    case Operations.pop_by_ref(state.pending, ref) do
      :error ->
        {:noreply, state}

      {:ok, %{type: :recovery}, pending} ->
        state = %{state | pending: pending}
        {:noreply, schedule_recovery_retry(state, {:recovery_task_exit, reason})}

      {:ok, %{type: :refill}, pending} ->
        state = %{state | pending: pending}
        {:noreply, schedule_refill_retry(state, {:refill_task_exit, reason})}

      {:ok, op, pending} ->
        retry_op = Operations.retry(op)
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
        # A first known submission may finish after retirement. Once dispatched,
        # uncertainty is reconciled by reads only; retirement must never recreate it.
        entry =
          if entry.automation_retired and entry.dispatched,
            do: %{entry | mode: :retired_reconcile},
            else: entry

        case Operations.start_submit(
               self(),
               state.task_supervisor,
               state.operation_timeout,
               entry,
               operation_context(state)
             ) do
          {:ok, submit_task} ->
            state = update_submit_head(state, &Map.put(&1, :dispatched, true))
            %{state | submit_task: submit_task}

          {:error, reason} ->
            Process.send_after(self(), {:retry_submit, entry.run_id}, @submit_retry_ms)

            state
            |> set_submit_head_mode(:reconcile)
            |> put_error({:submit_task_start_failed, reason})
        end
    end
  end

  defp start_submit_head(state), do: state

  defp start_operation(state, op) do
    case Operations.start(
           self(),
           state.task_supervisor,
           state.operation_timeout,
           op,
           operation_context(state)
         ) do
      {:ok, ref, pending_op} ->
        {:ok, %{state | pending: Map.put(state.pending, ref, pending_op)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_runner(state, run) do
    daemon = self()

    Execution.start_monitored_task(state.task_supervisor, fn ->
      _ = Registry.register(Synapsis.Agent.RunRegistry, run.id, nil)

      Execution.run(
        daemon,
        state.deps,
        state.task_supervisor,
        run,
        Execution.run_timeout(run, state.run_timeout),
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
          Execution.stop_delivery_child(Map.get(active, :delivery_pid))

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
    if publisher = Map.get(state, :status_publisher) do
      StatusPublisher.publish(publisher, Execution.status(state))
    end

    :ok
  end

  defp locate_run(state, run_id) do
    cond do
      state.active_run && state.active_run.run.id == run_id -> {:active, state.active_run}
      run = Enum.find(:queue.to_list(state.queue), &(&1.id == run_id)) -> {:queued, run}
      true -> :unknown
    end
  end

  defp overlapping?(state, attrs) do
    routine_id = Map.get(attrs, :routine_id)
    metadata = Map.get(attrs, :metadata, %{})
    no_overlap = Map.get(metadata, "no_overlap", Map.get(metadata, :no_overlap, false))

    no_overlap and is_binary(routine_id) and
      not idempotency_exists?(state.deps.runs, attrs) and
      Enum.any?(owned_runs(state), fn run ->
        run.routine_id == routine_id and same_automation?(run, attrs)
      end)
  end

  defp same_automation?(left, right) do
    case {automation_identity(left), automation_identity(right)} do
      {nil, _identity} -> true
      {_identity, nil} -> true
      {left_identity, right_identity} -> left_identity == right_identity
    end
  end

  defp automation_identity(%{routine_id: id, metadata: metadata}) when is_map(metadata) do
    ref = Map.get(metadata, "automation_ref", Map.get(metadata, :automation_ref))

    if is_map(ref) do
      source = Map.get(ref, "source", Map.get(ref, :source))
      ref_id = Map.get(ref, "id", Map.get(ref, :id))

      if source in ["routine", "heartbeat"] and ref_id == id and
           match?({:ok, ^id}, Ecto.UUID.cast(id)),
         do: {source, id}
    end
  end

  defp automation_identity(_run), do: nil

  defp take_automation_producer(state, pid) do
    case Map.pop(state.automation_producers, pid) do
      {nil, _producers} ->
        {nil, state}

      {producer, producers} ->
        Process.demonitor(producer.monitor, [:flush])
        {producer, %{state | automation_producers: producers}}
    end
  end

  defp captured_retirement_ids(state, target) do
    owned = for run <- owned_runs(state), automation_identity(run) == target, do: run.id
    recovered = for {id, ^target} <- state.automation_recovery_runs, do: id
    Enum.uniq(owned ++ recovered)
  end

  defp notify_submission_retirement(state, entry, id) do
    Enum.each(entry.retirement_refs, fn ref ->
      if observer = state.automation_retirement_observers[ref],
        do: notify_retirement_ids(ref, observer, [id])
    end)

    state
  end

  defp notify_retirement_ids(_ref, _observer, []), do: :ok

  defp notify_retirement_ids(ref, observer, ids),
    do: send(observer.scheduler, {:automation_retirement_runs, ref, self(), Enum.uniq(ids)})

  defp retirement_identity_complete?(state, ref, observer) do
    not (observer.recovery and recovery_chain?(state)) and
      not Enum.any?(state.automation_producers, fn {_pid, producer} ->
        MapSet.member?(producer.retirement_refs, ref)
      end) and
      not Enum.any?(:queue.to_list(state.submit_queue), fn entry ->
        MapSet.member?(entry.retirement_refs, ref)
      end)
  end

  defp finish_retirement_identities(state) do
    observers =
      Enum.reduce(state.automation_retirement_observers, %{}, fn {ref, observer}, pending ->
        if retirement_identity_complete?(state, ref, observer) do
          send(observer.scheduler, {:automation_retirement_identity_complete, ref, self()})
          pending
        else
          Map.put(pending, ref, observer)
        end
      end)

    %{state | automation_retirement_observers: observers}
  end

  defp request_matching_cancellations(state, target) do
    state =
      case state.active_run do
        %{run: run} = active ->
          if automation_identity(run) == target,
            do: request_active_cancellation(state, active),
            else: state

        nil ->
          state
      end

    Enum.reduce(:queue.to_list(state.queue), state, fn run, current ->
      if automation_identity(run) == target,
        do: request_queued_cancellation(current, run),
        else: current
    end)
  end

  defp request_active_cancellation(state, active) do
    state = %{
      state
      | automation_cancel_ids: MapSet.put(state.automation_cancel_ids, active.run.id),
        cancelling_ids: MapSet.put(state.cancelling_ids, active.run.id)
    }

    if active.cancelling do
      state
    else
      op = %{type: :cancel, from: nil, run_id: active.run.id, location: :active, active: active}
      state = %{state | active_run: %{active | cancelling: true, phase: :cancelling}}
      start_managed_cancel(state, op)
    end
  end

  defp request_queued_cancellation(state, run) do
    state = %{state | automation_cancel_ids: MapSet.put(state.automation_cancel_ids, run.id)}

    if MapSet.member?(state.cancelling_ids, run.id) do
      state
    else
      op = %{type: :cancel, from: nil, run_id: run.id, location: :queued, run: run}
      state = %{state | cancelling_ids: MapSet.put(state.cancelling_ids, run.id)}
      start_managed_cancel(state, op)
    end
  end

  defp start_managed_cancel(state, op) do
    case start_operation(state, op) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Process.send_after(self(), {:retry_operation, op}, @submit_retry_ms)
        put_error(state, reason)
    end
  end

  defp retry_managed_cancellation(state, id) do
    if MapSet.member?(state.automation_cancel_ids, id) do
      Process.send_after(self(), {:retry_automation_cancel, id}, @submit_retry_ms)
      %{state | cancelling_ids: MapSet.put(state.cancelling_ids, id)}
    else
      state
    end
  end

  defp reply_cancel(nil, _result), do: :ok
  defp reply_cancel(from, result), do: GenServer.reply(from, result)

  defp recovery_chain?(state) do
    not state.ready or state.recovery_backlog_count > 0 or
      pending_type?(state, :recovery) or pending_type?(state, :refill)
  end

  defp finish_automation_cancellation(state, id) do
    if recovery_chain?(state),
      do: state,
      else: %{state | automation_cancel_ids: MapSet.delete(state.automation_cancel_ids, id)}
  end

  defp merge_recovered_queue(state, runs) do
    owned = owned_run_ids(state)

    Enum.reduce(runs, state.queue, fn run, queue ->
      if MapSet.member?(owned, run.id), do: queue, else: :queue.in(run, queue)
    end)
  end

  defp apply_recovery_cancellations(state) do
    state =
      Enum.reduce(:queue.to_list(state.queue), state, fn run, current ->
        if MapSet.member?(current.automation_recovery_targets, automation_identity(run)) or
             MapSet.member?(current.automation_cancel_ids, run.id),
           do: request_queued_cancellation(current, run),
           else: current
      end)

    if recovery_chain?(state) do
      state
    else
      # Exact run intents outlive target guards while their existing cancel owns
      # cleanup. Completed IDs are retained only while a query can return them.
      outstanding = MapSet.intersection(state.automation_cancel_ids, state.cancelling_ids)

      %{
        state
        | automation_recovery_targets: MapSet.new(),
          automation_cancel_ids: outstanding,
          automation_recovery_runs: %{}
      }
      |> finish_retirement_identities()
    end
  end

  defp idempotency_exists?(runs, attrs) do
    key = Map.get(attrs, :idempotency_key)

    is_binary(key) and key != "" and function_exported?(runs, :get_by_idempotency_key, 1) and
      not is_nil(runs.get_by_idempotency_key(key))
  end

  defp owned_runs(state) do
    active = if state.active_run, do: [state.active_run.run], else: []
    queued = :queue.to_list(state.queue)
    submitting = state.submit_queue |> :queue.to_list() |> Enum.map(& &1.attrs)
    active ++ queued ++ submitting
  end

  defp pop_operation(state, pid) do
    case Operations.pop_by_pid(state.pending, pid) do
      {:ok, op, pending} ->
        {:ok, op, %{state | pending: pending}}

      :error ->
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

  defp update_submit_head(state, update) do
    case :queue.out(state.submit_queue) do
      {{:value, entry}, rest} -> %{state | submit_queue: :queue.in_r(update.(entry), rest)}
      {:empty, _queue} -> state
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

  defp operation_context(state) do
    %{
      owner: self(),
      deps: state.deps,
      task_supervisor: state.task_supervisor,
      cleanup_timeout: state.cleanup_timeout,
      event_timeout: state.event_timeout
    }
  end

  defp request_due_routine_check(pid) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :check_due_routines)
    :ok
  end

  defp request_due_routine_check(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> send(pid, :check_due_routines)
      nil -> :ok
    end

    :ok
  end

  defp request_due_routine_check(_target), do: :ok

  defp cancel_timer(ref), do: Operations.cancel_timer(ref)

  defp normalize_trigger_opts(opts) when is_map(opts), do: opts
  defp normalize_trigger_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_trigger_opts(_opts), do: %{}

  defp normalize_submit_opts(opts) do
    opts = normalize_trigger_opts(opts)

    case Map.fetch(opts, :agent) do
      {:ok, agent} ->
        opts
        |> Map.put(:assistant_name, agent)
        |> Map.update(:tool_profile, "read_only", fn
          "native_agent" -> "native_agent"
          _ -> "read_only"
        end)

      :error ->
        opts
    end
  end

  defp normalize_legacy_agent(opts) do
    case Map.fetch(opts, :agent) do
      {:ok, agent} ->
        opts
        |> Map.put_new(:assistant_name, agent)
        |> Map.put_new(:tool_profile, "heartbeat")
        |> Map.put_new(:source, "scheduler")

      :error ->
        opts
    end
  end

  defp maybe_put_heartbeat_id(opts, :heartbeat, routine_id) when is_binary(routine_id),
    do: Map.put_new(opts, :heartbeat_id, routine_id)

  defp maybe_put_heartbeat_id(opts, _kind, _routine_id), do: opts
end
