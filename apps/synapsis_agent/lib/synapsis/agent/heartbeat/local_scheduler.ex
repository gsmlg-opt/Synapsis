defmodule Synapsis.Agent.Heartbeat.LocalScheduler do
  @moduledoc """
  Node-local scheduler for daemon-backed heartbeat runs.

  Enabled configs are loaded from `Config.Store`. Each source and UUID own one timer;
  legacy cron strings skip missed occurrences, while typed routines retain their
  durable occurrence until its Run reconciles.
  """

  use GenServer
  require Logger

  alias Synapsis.Agent.{Daemon, RunEvents, Runs}
  alias Synapsis.Agent.Heartbeat.{CronSchedule, Schedule, Worker}
  alias Synapsis.Config.Store, as: ConfigStore

  @reload_interval_ms :timer.seconds(30)
  @public_status_timeout_ms :timer.seconds(5)
  @trigger_timeout_ms :timer.seconds(5)
  @persistence_retry_limit 2
  @persistence_retry_backoff_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the enabled heartbeat schedule for an explicit scheduler process."
  def status(server) when is_pid(server) or is_atom(server), do: GenServer.call(server, :status)

  @doc "Return the compatibility snapshot used by daemon health callers."
  def status() do
    %{degraded?: false, entries: status(__MODULE__)}
  end

  @doc "Return bounded node-local scheduler process status and the last reload outcome."
  def public_status(opts \\ []) do
    with {:ok, server, deadline} <- public_status_options(opts),
         :ok <- public_status_remaining(deadline),
         result <-
           GenServer.call(
             server,
             {:public_status, deadline},
             max(deadline - System.monotonic_time(:millisecond), 1)
           ),
         :ok <- public_status_remaining(deadline) do
      result
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @doc "Synchronously reload persisted routines and reconcile their timers."
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc "Remove a routine from runnable in-memory state after reconciliation fails."
  def fail_close(target) when is_binary(target) or is_tuple(target),
    do: fail_close(__MODULE__, target)

  def fail_close(server, target) when is_binary(target) or is_tuple(target),
    do: GenServer.call(server, {:fail_close, target})

  @doc "Submit a source-qualified routine, an unambiguous UUID, or a unique legacy name."
  def trigger(server \\ __MODULE__, identifier)
      when is_binary(identifier) or is_tuple(identifier) do
    GenServer.call(server, {:trigger, identifier}, @trigger_timeout_ms + 1_000)
  catch
    :exit, _reason -> {:error, :unknown_outcome}
  end

  @doc "Retire captured work after its configuration change has been committed."
  def retire(server, {source, id} = target, opts \\ [])
      when source in ["routine", "heartbeat"] and is_binary(id) do
    timeout = positive_timeout(opts[:timeout_ms], @trigger_timeout_ms)
    GenServer.call(server, {:retire, target, opts, timeout}, timeout + 1_000)
  catch
    :exit, _reason -> {:error, :unknown_outcome}
  end

  @doc "Reserve a due occurrence or force a run; admission runs outside the scheduler callback."
  def run(server, target, mode) when mode in [:due, :force] do
    GenServer.call(server, {:run, target, mode}, @trigger_timeout_ms + 1_000)
  catch
    # The scheduler may already have submitted a Run. A caller timeout is not rejection evidence.
    :exit, _reason -> {:error, :unknown_outcome}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      timers: %{},
      configs: [],
      reload_status: :pending,
      daemon: Keyword.get(opts, :daemon, Daemon),
      task_supervisor: Keyword.get(opts, :task_supervisor, Synapsis.Tool.TaskSupervisor),
      config_loader: Keyword.get(opts, :config_loader, &load_configs/0),
      config_writer: Keyword.get(opts, :config_writer, &merge_config/2),
      trigger_fun: Keyword.get(opts, :trigger_fun, &execute_config/2),
      trigger_timeout_ms: positive_timeout(opts[:trigger_timeout_ms], @trigger_timeout_ms),
      trigger_tasks: %{},
      unresolved_producers: %{},
      retired_run_ids: MapSet.new(),
      retirement_requests: %{},
      retirement_refs: %{},
      retirement_identity_cuts: %{},
      held_terminal_events: %{},
      daemon_monitors: %{},
      occurrence_submissions: %{},
      persistence_tasks: %{},
      pending_persistence: %{},
      persistence_snapshots: %{},
      persistence_retry_timers: %{},
      persistence_retry_limit:
        non_negative_integer(opts[:persistence_retry_limit], @persistence_retry_limit),
      persistence_retry_backoff_ms:
        positive_timeout(
          opts[:persistence_retry_backoff_ms],
          @persistence_retry_backoff_ms
        ),
      tracked_runs: %{},
      terminal_events: %{},
      terminal_results: %{},
      trigger_results: %{},
      reload_interval_ms: Keyword.get(opts, :reload_interval_ms, @reload_interval_ms)
    }

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:public_status, deadline}, _from, state) do
    result =
      with :ok <- public_status_remaining(deadline) do
        reload_status =
          case state.reload_status do
            :pending -> "pending"
            :ok -> "ok"
            :failed -> "failed"
          end

        {:ok, %{engine: "node_local", running: true, reload_status: reload_status}}
      end

    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    entries =
      state.timers
      |> Enum.map(fn {key, timer} ->
        config = config_by_id(state.configs, key)

        base = %{
          id: value(config, :id),
          name: value(config, :name),
          kind: value(config, :kind, "heartbeat"),
          schedule: timer.schedule,
          timezone: Map.get(timer, :timezone, "Etc/UTC"),
          next_run_at: timer.next_run_at
        }

        base =
          case config_source(config) do
            nil -> base
            source -> Map.put(base, :source, source)
          end

        Map.merge(base, Map.get(state.trigger_results, key, %{}))
      end)
      |> Enum.sort_by(&{&1.name, &1.id, Map.get(&1, :source)})

    {:reply, entries, state}
  end

  def handle_call(:reload, _from, state) do
    state = reload_configs(state)
    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("heartbeat_reload_failed", reason: Exception.message(error))
      {:reply, {:error, :reload_failed}, %{state | reload_status: :failed}}
  end

  def handle_call({:fail_close, target}, _from, state) do
    {removed, configs} = Enum.split_with(state.configs, &fail_close_target?(&1, target))

    timers =
      Enum.reduce(removed, state.timers, fn config, timers ->
        key = routine_key(config)
        if timer = Map.get(timers, key), do: cancel_timer(timer)
        Map.delete(timers, key)
      end)

    {:reply, :ok, %{state | timers: timers, configs: configs}}
  end

  def handle_call({:trigger, identifier}, from, state) do
    case resolve_config(state.configs, identifier) do
      {:ok, config} ->
        key = routine_key(config)

        if value(config, :enabled, true) == false do
          {:reply, {:error, :disabled}, state}
        else
          slot = get_in(state.timers, [key, :next_run_at])
          config = prepare_trigger(config, slot, true)

          {:noreply,
           start_trigger_task(state, key, config, slot,
             from: from,
             mode: :manual,
             task_key: {key, make_ref()}
           )}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:retire, target, opts, timeout}, from, state) do
    state = retire_local_work(state, target, opts[:config])

    daemons =
      [GenServer.whereis(state.daemon)] ++
        Enum.map(state.trigger_tasks, fn {_key, task} ->
          if task.key == target, do: task.daemon
        end) ++
        Enum.map(state.unresolved_producers, fn {_ref, task} ->
          if task.key == target, do: task.daemon
        end) ++
        Enum.map(state.tracked_runs, fn {_id, tracked} ->
          if tracked.key == target, do: Map.get(tracked, :daemon)
        end)

    daemons = daemons |> Enum.filter(&is_pid/1) |> Enum.uniq()
    captured_ids = for {id, tracked} <- state.tracked_runs, tracked.key == target, do: id
    state = accept_retired_run_ids(state, captured_ids)
    request_ref = make_ref()
    timeout_ref = Process.send_after(self(), {:retirement_timeout, request_ref}, timeout)

    request = %{
      from: from,
      target: target,
      pending: %{},
      observations: [],
      unknown: daemons == [],
      timeout_ref: timeout_ref
    }

    state = put_in(state.retirement_requests[request_ref], request)

    state =
      if daemons == [],
        do:
          put_in(state.retirement_identity_cuts[request_ref], %{
            daemon: nil,
            target: target,
            status: :unknown
          }),
        else: state

    state =
      Enum.reduce(daemons, state, fn daemon, acc ->
        acc = monitor_daemon(acc, daemon)
        ref = make_ref()

        acc =
          put_in(acc.retirement_identity_cuts[ref], %{
            daemon: daemon,
            target: target,
            status: :pending
          })

        :ok = Daemon.request_automation_cancellation(daemon, self(), ref, target)

        acc
        |> put_in([:retirement_requests, request_ref, :pending, ref], daemon)
        |> put_in([:retirement_refs, ref], request_ref)
      end)

    {:noreply, finish_retirement(state, request_ref)}
  end

  def handle_call({:run, target, mode}, from, state) do
    case resolve_config(state.configs, target) do
      {:ok, config} -> request_run(state, config, mode, from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = reload_configs(state)
    Process.send_after(self(), :tick, state.reload_interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("heartbeat_reload_failed", reason: Exception.message(error))
      Process.send_after(self(), :tick, state.reload_interval_ms)
      {:noreply, %{state | reload_status: :failed}}
  end

  def handle_info(:check_due_routines, state) do
    {:noreply, reload_configs(state)}
  rescue
    error ->
      Logger.warning("heartbeat_due_check_failed", reason: Exception.message(error))
      {:noreply, %{state | reload_status: :failed}}
  end

  def handle_info({:fire, key, token}, state) do
    case {state.timers[key], config_by_id(state.configs, key)} do
      {%{token: ^token} = timer, config} when not is_nil(config) ->
        cond do
          DateTime.compare(timer.next_run_at, DateTime.utc_now()) == :gt ->
            timers = Map.put(state.timers, key, arm_timer(timer, key))
            {:noreply, %{state | timers: timers}}

          typed_schedule?(config) ->
            config = prepare_trigger(config, timer.next_run_at, false)
            timers = Map.put(state.timers, key, %{timer | ref: nil})

            {:noreply,
             start_trigger_task(%{state | timers: timers}, key, config, timer.next_run_at)}

          true ->
            Logger.info("heartbeat_firing", routine_id: key, name: value(config, :name))
            config = prepare_due_trigger(config, timer.next_run_at)
            timers = state.timers |> Map.delete(key) |> schedule_config(config)

            state =
              state
              |> Map.put(:timers, timers)
              |> persist_next_run(config, get_in(timers, [key, :next_run_at]))

            {:noreply,
             start_trigger_task(state, key, config, get_in(timers, [key, :next_run_at]))}
        end

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      trigger = Enum.find(state.trigger_tasks, fn {_key, task} -> task.monitor == ref end) ->
        {key, task} = trigger
        cancel_trigger_task_tracking(task)
        {config, trigger_result, last_run_at, next_run_at} = result

        reply_subscribers(task, trigger_result)

        state =
          state
          |> delete_trigger_task(key)
          |> record_submission(task, trigger_result)
          |> finish_trigger(task, config, trigger_result, last_run_at, next_run_at)

        {:noreply, state}

      task = Map.get(state.persistence_tasks, ref) ->
        cancel_persistence_task_tracking(task)
        {:noreply, finish_persistence_task(state, ref, task, result)}

      task = Map.get(state.unresolved_producers, ref) ->
        {config, trigger_result, last_run_at, next_run_at} = result

        state = %{state | unresolved_producers: Map.delete(state.unresolved_producers, ref)}
        {:noreply, finish_trigger(state, task, config, trigger_result, last_run_at, next_run_at)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:automation_producer_ready, ref, daemon}, state) do
    tasks =
      Map.new(state.trigger_tasks, fn {key, task} ->
        {key,
         if(task.producer_ref == ref and task.daemon == daemon,
           do: %{task | registered: true},
           else: task
         )}
      end)

    {:noreply, %{state | trigger_tasks: tasks}}
  end

  def handle_info({:automation_cancellation_requested, ref, observation}, state) do
    case Map.fetch(state.retirement_refs, ref) do
      {:ok, request_ref} ->
        state = accept_retired_run_ids(state, Map.get(observation, :retired_run_ids, []))

        state =
          if Map.get(observation, :identity_complete, false),
            do: close_retirement_identity_cut(state, ref),
            else: state

        request = state.retirement_requests[request_ref]

        request = %{
          request
          | pending: Map.delete(request.pending, ref),
            observations: [observation | request.observations]
        }

        state =
          state
          |> put_in([:retirement_requests, request_ref], request)
          |> Map.put(:retirement_refs, Map.delete(state.retirement_refs, ref))

        {:noreply, finish_retirement(state, request_ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:automation_retirement_runs, ref, daemon, ids}, state) do
    case state.retirement_identity_cuts[ref] do
      %{daemon: ^daemon} -> {:noreply, accept_retired_run_ids(state, ids)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:automation_retirement_identity_complete, ref, daemon}, state) do
    case state.retirement_identity_cuts[ref] do
      %{daemon: ^daemon} -> {:noreply, close_retirement_identity_cut(state, ref)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:retirement_timeout, ref}, state) do
    case state.retirement_requests[ref] do
      %{from: from} = request when not is_nil(from) ->
        GenServer.reply(from, {:error, :unknown_outcome})

        cuts =
          Map.new(state.retirement_identity_cuts, fn {cut_ref, cut} ->
            {cut_ref,
             if(Map.has_key?(request.pending, cut_ref), do: %{cut | status: :unknown}, else: cut)}
          end)

        state = %{state | retirement_identity_cuts: cuts}
        {:noreply, put_in(state.retirement_requests[ref], %{request | from: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:trigger_timeout, key, pid}, state) do
    case state.trigger_tasks[key] do
      %{pid: ^pid} = task ->
        Process.exit(pid, :kill)
        cancel_trigger_task_tracking(task)
        reply_subscribers(task, {:error, :unknown_outcome})

        {:noreply,
         state
         |> retain_unresolved_producer(task)
         |> delete_trigger_task(key)
         |> record_submission(task, {:error, :unknown_outcome})
         |> put_trigger_error(task.key, :trigger_timeout)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:persistence_timeout, ref, pid}, state) do
    case state.persistence_tasks[ref] do
      %{pid: ^pid} = task ->
        Process.exit(pid, :kill)
        cancel_persistence_task_tracking(task)

        {:noreply, finish_persistence_task(state, ref, task, {:error, :config_persist_timeout})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_persistence, key, token}, state) do
    case state.persistence_retry_timers[key] do
      %{token: ^token, type: type, kind: kind, attrs: attrs, attempt: attempt} ->
        state = %{
          state
          | persistence_retry_timers: Map.delete(state.persistence_retry_timers, key)
        }

        {:noreply, start_persistence_task(state, key, type, kind, attrs, attempt)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:agent_daemon_event, %{event: event, run_id: run_id, status: status} = payload},
        state
      )
      when event in [
             "agent.run.completed",
             "agent.run.failed",
             "agent.run.cancelled",
             "agent.run.interrupted"
           ] do
    {:noreply, handle_terminal_event(state, run_id, status, payload)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    cond do
      daemon = Enum.find(state.daemon_monitors, fn {_pid, ref} -> ref == monitor end) ->
        {pid, _ref} = daemon
        {:noreply, daemon_down(state, pid)}

      trigger = Enum.find(state.trigger_tasks, fn {_key, task} -> task.monitor == monitor end) ->
        {key, task} = trigger
        cancel_timeout(task.timeout_ref)
        reply_subscribers(task, {:error, :unknown_outcome})

        {:noreply,
         state
         |> retain_unresolved_producer(task)
         |> delete_trigger_task(key)
         |> record_submission(task, {:error, :unknown_outcome})
         |> put_trigger_error(task.key, {:trigger_task_down, reason})}

      task = Map.get(state.persistence_tasks, monitor) ->
        cancel_timeout(task.timeout_ref)

        {:noreply,
         finish_persistence_task(
           state,
           monitor,
           task,
           {:error, {:config_persist_task_down, reason}}
         )}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp retire_local_work(state, target, disabled_config) do
    if timer = state.timers[target], do: cancel_timer(timer)

    configs = Enum.reject(state.configs, &(routine_key(&1) == target))

    configs =
      if is_map(disabled_config),
        do: [Map.put(disabled_config, "__config_type", elem(target, 0)) | configs],
        else: configs

    retire = fn entries ->
      Map.new(entries, fn {ref, item} ->
        {ref, if(item.key == target, do: Map.put(item, :retired, true), else: item)}
      end)
    end

    state = cancel_persistence_retry(state, target)

    retired_ids =
      Enum.reduce(state.tracked_runs, state.retired_run_ids, fn {id, run}, ids ->
        if run.key == target, do: MapSet.put(ids, id), else: ids
      end)

    %{
      state
      | configs: configs,
        timers: Map.delete(state.timers, target),
        occurrence_submissions: Map.delete(state.occurrence_submissions, target),
        trigger_tasks: retire.(state.trigger_tasks),
        unresolved_producers: retire.(state.unresolved_producers),
        tracked_runs: retire.(state.tracked_runs),
        retired_run_ids: retired_ids,
        persistence_tasks: retire.(state.persistence_tasks),
        pending_persistence: Map.delete(state.pending_persistence, target),
        persistence_snapshots: Map.delete(state.persistence_snapshots, target)
    }
  end

  defp monitor_daemon(state, daemon) do
    if Map.has_key?(state.daemon_monitors, daemon),
      do: state,
      else: put_in(state.daemon_monitors[daemon], Process.monitor(daemon))
  end

  defp accept_retired_run_ids(state, ids) do
    %{
      state
      | retired_run_ids: Enum.reduce(ids, state.retired_run_ids, &MapSet.put(&2, &1)),
        tracked_runs: Map.drop(state.tracked_runs, ids),
        terminal_events: Map.drop(state.terminal_events, ids),
        held_terminal_events: Map.drop(state.held_terminal_events, ids)
    }
  end

  defp retirement_identity_pending?(state, target) do
    Enum.any?(state.retirement_identity_cuts, fn {_ref, cut} -> cut.target == target end)
  end

  defp close_retirement_identity_cut(state, ref) do
    state = %{
      state
      | retirement_identity_cuts: Map.delete(state.retirement_identity_cuts, ref)
    }

    # IDs precede completion on the pinned owner's message stream. Cleanup may
    # still be pending; only terminal schedule provenance is now complete.
    Enum.reduce(state.held_terminal_events, state, fn {id, event}, acc ->
      tracked = Map.get(acc.tracked_runs, id)

      if terminal_identity_pending?(acc, tracked, event.payload) do
        acc
      else
        acc = %{acc | held_terminal_events: Map.delete(acc.held_terminal_events, id)}
        handle_terminal_event(acc, id, event.status, event.payload)
      end
    end)
  end

  defp terminal_identity_pending?(state, %{key: target}, _payload),
    do: retirement_identity_pending?(state, target)

  defp terminal_identity_pending?(state, _tracked, %{payload: payload}) do
    ref = value(payload, :automation_ref)

    if is_map(ref) and value(ref, :source) in ["routine", "heartbeat"] and
         is_binary(value(ref, :id)) do
      retirement_identity_pending?(state, {value(ref, :source), value(ref, :id)})
    else
      id = value(payload, :routine_id)

      Enum.any?(state.retirement_identity_cuts, fn {_ref, cut} -> elem(cut.target, 1) == id end)
    end
  end

  defp terminal_identity_pending?(_state, _tracked, _payload), do: false

  defp hold_terminal_event(state, run_id, status, payload) do
    put_in(state.held_terminal_events[run_id], %{status: status, payload: payload})
  end

  defp daemon_down(state, daemon) do
    cuts =
      Map.new(state.retirement_identity_cuts, fn {ref, cut} ->
        {ref, if(cut.daemon == daemon, do: %{cut | status: :unknown}, else: cut)}
      end)

    state = %{
      state
      | daemon_monitors: Map.delete(state.daemon_monitors, daemon),
        retirement_identity_cuts: cuts
    }

    Enum.reduce(Map.keys(state.retirement_requests), state, fn ref, acc ->
      request = acc.retirement_requests[ref]
      {lost, pending} = Enum.split_with(request.pending, fn {_ref, pid} -> pid == daemon end)

      if lost == [] do
        acc
      else
        refs =
          Enum.reduce(lost, acc.retirement_refs, fn {ref, _pid}, refs -> Map.delete(refs, ref) end)

        request = %{request | pending: Map.new(pending), unknown: true}

        acc
        |> Map.put(:retirement_refs, refs)
        |> put_in([:retirement_requests, ref], request)
        |> finish_retirement(ref)
      end
    end)
  end

  defp finish_retirement(state, ref) do
    request = state.retirement_requests[ref]

    if map_size(request.pending) == 0 do
      cancel_timeout(request.timeout_ref)

      result =
        if request.unknown,
          do: {:error, :unknown_outcome},
          else: {:ok, retirement_observation(request)}

      if request.from, do: GenServer.reply(request.from, result)

      if request.unknown,
        do: put_in(state.retirement_requests[ref], %{request | from: nil}),
        else: %{state | retirement_requests: Map.delete(state.retirement_requests, ref)}
    else
      state
    end
  end

  defp retirement_observation(request) do
    counts =
      Map.new(
        [
          :active_count,
          :queued_count,
          :submission_count,
          :producer_count,
          :pending_recovery_count,
          :pending_refill_count
        ],
        fn key -> {key, Enum.sum(Enum.map(request.observations, &Map.fetch!(&1, key)))} end
      )

    Map.merge(counts, %{
      status: :cancellation_requested,
      target: request.target,
      observations: Enum.reverse(request.observations),
      cleanup_pending: Enum.any?(request.observations, & &1.cleanup_pending)
    })
  end

  defp retain_unresolved_producer(state, task) do
    put_in(state.unresolved_producers[task.monitor], %{task | waiters: []})
  end

  defp finish_trigger(state, %{retired: true}, config, {:ok, %{id: id} = run}, _last, _next) do
    RunEvents.publish_routine_triggered(config, run)
    accept_retired_run_ids(state, [id])
  end

  defp finish_trigger(state, %{retired: true} = task, _config, _result, _last, _next),
    do: retain_unresolved_producer(state, task)

  defp finish_trigger(state, task, config, result, last_run_at, next_run_at) do
    case result do
      {:ok, %{id: id} = run} ->
        if MapSet.member?(state.retired_run_ids, id),
          do:
            finish_trigger(
              state,
              %{task | retired: true},
              config,
              {:ok, run},
              last_run_at,
              next_run_at
            ),
          else: finish_current_trigger(state, task, config, result, last_run_at, next_run_at)

      _ ->
        finish_current_trigger(state, task, config, result, last_run_at, next_run_at)
    end
  end

  defp finish_current_trigger(state, task, config, result, last_run_at, next_run_at) do
    state = track_trigger(state, task.key, config, result, last_run_at, next_run_at)

    case result do
      {:ok, %{id: id}} ->
        if Map.has_key?(state.tracked_runs, id),
          do:
            put_in(state.tracked_runs[id], Map.put(state.tracked_runs[id], :daemon, task.daemon)),
          else: state

      {:error, :unknown_outcome} ->
        retain_unresolved_producer(state, task)

      {:error, {:exit, _reason}} ->
        retain_unresolved_producer(state, task)

      _ ->
        state
    end
  end

  defp reload_configs(state) do
    configs = state.config_loader.()
    state = %{state | configs: configs}

    state =
      Enum.reduce(configs, state, fn config, acc ->
        if typed_schedule?(config) and not materialized?(config),
          do:
            enqueue_persistence(acc, routine_key(config), :routine, value(config, :kind), %{
              "id" => value(config, :id),
              "__materialize" => true
            }),
          else: acc
      end)

    enabled_configs =
      Enum.filter(
        configs,
        &(value(&1, :enabled, true) != false and (not typed_schedule?(&1) or materialized?(&1)))
      )

    timers = reconcile_timers(state.timers, enabled_configs)

    state = %{state | timers: timers, configs: configs}

    state =
      Enum.reduce(enabled_configs, state, fn config, acc ->
        next_run_at = get_in(timers, [routine_key(config), :next_run_at])

        if same_datetime?(value(config, :next_run_at), next_run_at),
          do: acc,
          else: persist_next_run(acc, config, next_run_at)
      end)

    submissions =
      Map.filter(state.occurrence_submissions, fn {key, reserved} ->
        case config_by_id(configs, key) do
          nil -> false
          config -> reserved.identity == schedule_identity(config)
        end
      end)

    %{state | reload_status: :ok, occurrence_submissions: submissions}
  end

  defp public_status_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:server, :deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = System.monotonic_time(:millisecond) + @public_status_timeout_ms
      deadline = Keyword.get(opts, :deadline, ceiling)
      server = Keyword.get(opts, :server, __MODULE__)

      if is_integer(deadline) and (is_pid(server) or (is_atom(server) and not is_nil(server))),
        do: {:ok, server, min(deadline, ceiling)},
        else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp public_status_options(_opts), do: {:error, :invalid_input}

  defp public_status_remaining(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :timeout}
  end

  defp reconcile_timers(timers, configs) do
    timers =
      Enum.reduce(timers, %{}, fn {key, timer}, kept ->
        config = config_by_id(configs, key)

        if config && value(config, :schedule_generation) == Map.get(timer, :generation) &&
             value(config, :schedule) == timer.schedule &&
             schedule_timezone(config) ==
               {:ok, Map.get(timer, :timezone, "Etc/UTC")} do
          Map.put(kept, key, timer)
        else
          cancel_timer(timer)
          kept
        end
      end)

    Enum.reduce(configs, timers, fn config, acc ->
      key = routine_key(config)

      if Map.has_key?(acc, key),
        do: acc,
        else: schedule_config(acc, config)
    end)
  end

  defp schedule_config(timers, config) do
    key = routine_key(config)
    name = value(config, :name)
    schedule = value(config, :schedule)

    case next_run(config) do
      {:ok, delay_ms, next_run_at, timezone} ->
        token = make_ref()
        ref = Process.send_after(self(), {:fire, key, token}, delay_ms)

        Map.put(timers, key, %{
          ref: ref,
          token: token,
          schedule: schedule,
          generation: value(config, :schedule_generation),
          timezone: timezone,
          next_run_at: next_run_at
        })

      :none ->
        timers

      {:error, reason} ->
        Logger.warning("heartbeat_schedule_skip", name: name, reason: inspect(reason))
        timers
    end
  end

  defp next_run(config) do
    now = DateTime.utc_now()

    with {:ok, timezone} <- schedule_timezone(config),
         {:ok, next_run_at} <- next_occurrence(config, timezone, now) do
      delay_ms = timer_delay(next_run_at)
      {:ok, delay_ms, next_run_at, timezone}
    end
  end

  defp schedule_timezone(config) do
    timezone =
      case value(config, :schedule) do
        %{"kind" => "cron", "tz" => timezone} -> timezone
        _ -> value(config, :timezone)
      end

    CronSchedule.normalize_timezone(timezone)
  end

  defp next_occurrence(config, timezone, now) do
    if typed_schedule?(config) do
      case parse_datetime(value(config, :next_run_at)) do
        %DateTime{} = persisted ->
          {:ok, persisted}

        nil ->
          case value(config, :schedule) do
            %{"kind" => "at", "at" => at} -> Synapsis.RoutineSchedule.parse_at(at)
            schedule -> Schedule.next_after(schedule, timezone, now, value(config, :id))
          end
      end
    else
      CronSchedule.next_after(value(config, :schedule), timezone, now)
    end
  end

  # Large delays are bounded wakes, never early executions.
  defp timer_delay(next_run_at),
    do:
      next_run_at
      |> DateTime.diff(DateTime.utc_now(), :millisecond)
      |> max(1)
      |> min(2_147_000_000)

  defp arm_timer(timer, key) do
    token = make_ref()

    %{
      timer
      | token: token,
        ref: Process.send_after(self(), {:fire, key, token}, timer_delay(timer.next_run_at))
    }
  end

  defp load_configs do
    Enum.map(ConfigStore.list(:heartbeat), &Map.put(&1, "__config_type", "heartbeat")) ++
      Enum.map(ConfigStore.list(:routine), &Map.put(&1, "__config_type", "routine"))
  rescue
    _error ->
      Enum.map(Synapsis.Heartbeats.list_enabled(), fn config ->
        config |> Map.from_struct() |> Map.put("__config_type", "heartbeat")
      end)
  end

  defp execute_config(config, daemon) do
    case value(config, :kind, "heartbeat") do
      "heartbeat" -> Worker.execute(config, daemon)
      "schedule" -> Daemon.trigger(daemon, :schedule, routine_options(config))
      "dream" -> Daemon.trigger(daemon, :dream, routine_options(config))
      _unknown -> {:error, :unsupported_routine_kind}
    end
  end

  defp request_run(state, config, :force, from) do
    key = routine_key(config)
    slot = get_in(state.timers, [key, :next_run_at])
    prepared = config |> Map.put("enabled", true) |> prepare_trigger(slot, true)

    {:noreply,
     start_trigger_task(state, key, prepared, slot,
       from: from,
       mode: :force,
       task_key: {key, make_ref()}
     )}
  end

  defp request_run(state, config, :due, from) do
    key = routine_key(config)

    slot =
      get_in(state.timers, [key, :next_run_at]) || parse_datetime(value(config, :next_run_at))

    reserved = state.occurrence_submissions[key]

    cond do
      value(config, :enabled, true) == false ->
        {:reply, {:ok, %{enqueued: false, run: nil, reason: :disabled}}, state}

      reserved && reserved.identity == schedule_identity(config) &&
          (reserved.slot == slot or reserved.result == :pending or
             submission_active?(state, reserved.result)) ->
        case reserved.result do
          :pending ->
            state = update_in(state.trigger_tasks[reserved.task_key].waiters, &[from | &1])
            {:noreply, state}

          result ->
            {:reply, run_ack(result), state}
        end

      is_nil(slot) or DateTime.compare(slot, DateTime.utc_now()) == :gt ->
        {:reply, {:ok, %{enqueued: false, run: nil, reason: :not_due}}, state}

      true ->
        prepared = prepare_due_trigger(config, slot)
        state = consume_due_timer(state, key, config)
        next_run_at = get_in(state.timers, [key, :next_run_at])
        {:noreply, start_trigger_task(state, key, prepared, next_run_at, from: from)}
    end
  end

  defp submission_active?(state, {:ok, %{id: id}}), do: Map.has_key?(state.tracked_runs, id)
  defp submission_active?(_state, _result), do: false

  defp consume_due_timer(state, key, config) do
    if timer = state.timers[key], do: cancel_timer(timer)

    if typed_schedule?(config) do
      case state.timers[key] do
        nil -> state
        timer -> put_in(state.timers[key], %{timer | ref: nil})
      end
    else
      timers = state.timers |> Map.delete(key) |> schedule_config(config)

      state
      |> Map.put(:timers, timers)
      |> persist_next_run(config, get_in(timers, [key, :next_run_at]))
    end
  end

  defp schedule_identity(config) do
    {routine_key(config), value(config, :schedule_generation), value(config, :schedule),
     value(config, :timezone)}
  end

  defp prepare_due_trigger(config, slot) do
    if typed_schedule?(config) do
      prepare_trigger(config, slot, false)
    else
      # Legacy cron and typed schedules use the same scheduler reservation path.
      # Source remains part of the durable identity even when UUIDs are shared.
      identity = {schedule_identity(config), encode_datetime(slot)}

      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary(identity))
        |> Base.url_encode64(padding: false)

      config
      |> Map.put("__idempotency_key", "automation-occurrence:" <> digest)
      |> Map.put("__scheduled_for", slot)
    end
  end

  defp run_ack({:ok, %Synapsis.AgentRun{} = run}),
    do: {:ok, %{enqueued: true, run: run, reason: nil}}

  defp run_ack({:error, _} = error), do: error
  defp run_ack(_), do: {:error, :unknown_outcome}

  defp reply_subscribers(task, result) do
    reply = if task.mode == :manual, do: result, else: run_ack(result)
    for from <- task.waiters, do: GenServer.reply(from, reply)
  end

  defp record_submission(state, %{mode: mode}, _result) when mode != :due, do: state

  defp record_submission(state, task, result) do
    case state.occurrence_submissions[task.key] do
      %{task_key: task_key} = reserved when task_key == task.task_key ->
        put_in(state.occurrence_submissions[task.key], %{reserved | result: result})

      _ ->
        state
    end
  end

  defp start_trigger_task(state, key, config, next_run_at, opts \\ []) do
    task_key = Keyword.get(opts, :task_key, key)
    mode = Keyword.get(opts, :mode, :due)
    occurrence_key = value(config, :__idempotency_key)
    prior = state.occurrence_submissions[key]

    if Map.has_key?(state.trigger_tasks, task_key) or
         ((mode == :due and prior) && prior.occurrence_key == occurrence_key) do
      state
    else
      try do
        daemon = GenServer.whereis(state.daemon)
        true = is_pid(daemon)
        context = %{trigger_context(state, next_run_at) | daemon: daemon}
        producer_ref = make_ref()
        timeout = state.trigger_timeout_ms

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            daemon_monitor = Process.monitor(daemon)
            last_run_at = DateTime.utc_now()

            result =
              receive do
                {:automation_producer_ready, ^producer_ref, ^daemon} ->
                  protect(fn -> submit_config(config, context) end)

                {:DOWN, ^daemon_monitor, :process, ^daemon, _reason} ->
                  {:error, :unknown_outcome}
              after
                timeout -> {:error, :unknown_outcome}
              end

            Process.demonitor(daemon_monitor, [:flush])
            {config, result, last_run_at, context.next_run_at}
          end)

        timeout_ref =
          Process.send_after(
            self(),
            {:trigger_timeout, task_key, task.pid},
            state.trigger_timeout_ms
          )

        tracked = %{
          pid: task.pid,
          monitor: task.ref,
          timeout_ref: timeout_ref,
          key: key,
          task_key: task_key,
          producer_ref: producer_ref,
          daemon: daemon,
          registered: false,
          retired: false,
          mode: mode,
          waiters: if(opts[:from], do: [opts[:from]], else: [])
        }

        state = monitor_daemon(state, daemon)
        state = %{state | trigger_tasks: Map.put(state.trigger_tasks, task_key, tracked)}
        :ok = Daemon.register_automation_producer(daemon, self(), producer_ref, task.pid, key)

        if mode == :due do
          reserved = %{
            identity: schedule_identity(config),
            occurrence_key: occurrence_key,
            slot: value(config, :__scheduled_for),
            task_key: task_key,
            result: :pending
          }

          put_in(state.occurrence_submissions[key], reserved)
        else
          state
        end
      rescue
        error ->
          if opts[:from], do: GenServer.reply(opts[:from], {:error, :unknown_outcome})
          put_trigger_error(state, key, {:trigger_task_start_failed, error})
      catch
        :exit, reason ->
          if opts[:from], do: GenServer.reply(opts[:from], {:error, :unknown_outcome})
          put_trigger_error(state, key, {:trigger_task_start_failed, reason})
      end
    end
  end

  defp typed_schedule?(config),
    do: config_type(config) == :routine and is_map(value(config, :schedule))

  defp materialized?(config) do
    schedule = value(config, :schedule)
    fingerprint = value(config, :schedule_fingerprint)

    is_binary(value(config, :schedule_generation)) and is_integer(value(config, :createdAtMs)) and
      is_binary(fingerprint) and
      Synapsis.RoutineSchedule.fingerprint(schedule, value(config, :timezone)) ==
        {:ok, fingerprint} and
      (value(schedule, :kind) != "every" or is_integer(value(schedule, :anchorMs)))
  end

  defp prepare_trigger(config, slot, manual?) do
    if typed_schedule?(config) do
      slot =
        slot ||
          case next_occurrence(config, value(config, :timezone), DateTime.utc_now()) do
            {:ok, instant} -> instant
            _ -> nil
          end

      advance? =
        not manual? or
          (value(value(config, :schedule), :kind) == "at" and match?(%DateTime{}, slot) and
             DateTime.compare(slot, DateTime.utc_now()) != :gt)

      occurrence = encode_datetime(slot)
      generation = value(config, :schedule_generation)
      attempt = if advance?, do: "occurrence", else: "manual:" <> Ecto.UUID.generate()
      key = Enum.join(["routine", value(config, :id), generation, occurrence, attempt], ":")

      context = %{
        "generation" => generation,
        "occurrence" => occurrence,
        "advance" => advance?,
        "preserved_next_run_at" => occurrence
      }

      config
      |> Map.put("__schedule_context", context)
      |> Map.put("__idempotency_key", key)
      |> Map.put("__scheduled_for", slot)
    else
      config
    end
  end

  defp submit_config(config, context) do
    case value(config, :__idempotency_key) do
      nil ->
        context.trigger_fun.(config, context.daemon)

      key ->
        case Runs.fetch_by_idempotency_key(key) do
          {:ok, _run} ->
            context.trigger_fun.(config, context.daemon)

          :not_found when not is_map_key(config, "__schedule_context") ->
            context.trigger_fun.(config, context.daemon)

          :not_found ->
            attrs =
              schedule_guard(
                %{
                  "id" => value(config, :id),
                  "next_run_at" => value(value(config, :__schedule_context), :occurrence)
                },
                config
              )

            with result when result == :ok or elem(result, 0) == :ok <-
                   context.config_writer.(:routine, attrs),
                 do: context.trigger_fun.(config, context.daemon)

          {:error, _} = error ->
            error
        end
    end
  end

  defp restore_schedule_context(config, context) when is_map(context),
    do: Map.put(config, "__schedule_context", context)

  defp restore_schedule_context(config, _), do: config

  defp schedule_guard(attrs, config) do
    context = value(config, :__schedule_context, %{})
    generation = value(context, :generation, value(config, :schedule_generation))

    cond do
      config_type(config) != :routine ->
        attrs

      is_binary(generation) ->
        Map.put(attrs, "__schedule_generation", generation)

      true ->
        case Synapsis.RoutineSchedule.fingerprint(
               value(config, :schedule),
               value(config, :timezone)
             ) do
          {:ok, fingerprint} -> Map.put(attrs, "__schedule_fingerprint", fingerprint)
          {:error, _} -> Map.put(attrs, "__schedule_fingerprint", :invalid)
        end
    end
  end

  defp persist_typed_terminal(state, tracked, status, payload) do
    config = tracked.config
    context = value(config, :__schedule_context, %{})
    generation = value(context, :generation)
    current = config_by_id(state.configs, tracked.key)
    started_at = terminal_started_at(Map.get(payload, :payload, %{})) || tracked.last_run_at
    status = webhook_completion_status(config, status, payload)

    observable = %{
      last_run_at: encode_datetime(started_at),
      last_status: status,
      last_error: terminal_error(payload)
    }

    state = %{
      state
      | trigger_results: Map.put(state.trigger_results, tracked.key, observable),
        terminal_results: Map.put(state.terminal_results, tracked.key, observable)
    }

    if current && is_binary(generation) && value(current, :schedule_generation) == generation do
      {attrs, next_run_at} = typed_outcome(config, context, status, started_at)

      attrs =
        routine_state(config, status, started_at, next_run_at)
        |> Map.merge(attrs)
        |> schedule_guard(config)

      updated =
        Map.merge(current, Map.drop(attrs, ["__schedule_generation", "__delete_after_run"]))

      previous_timer = state.timers[tracked.key]
      if previous_timer, do: cancel_timer(previous_timer)
      timers = Map.delete(state.timers, tracked.key)
      retire? = attrs["__delete_after_run"] == true

      configs =
        if retire?,
          do: Enum.reject(state.configs, &(routine_key(&1) == tracked.key)),
          else:
            Enum.map(state.configs, fn entry ->
              if routine_key(entry) == tracked.key, do: updated, else: entry
            end)

      # Failed/unknown outcomes remain unfinished; no retry or retirement policy is invented.
      timers =
        cond do
          retire? or value(updated, :enabled, true) == false ->
            timers

          status == "completed" or value(context, :advance) != true ->
            schedule_config(timers, updated)

          match?(%DateTime{}, next_run_at) ->
            held = %{
              ref: nil,
              token: make_ref(),
              schedule: value(updated, :schedule),
              generation: value(updated, :schedule_generation),
              timezone: Map.get(previous_timer || %{}, :timezone, "Etc/UTC"),
              next_run_at: next_run_at
            }

            Map.put(timers, tracked.key, held)

          true ->
            timers
        end

      state = %{state | configs: configs, timers: timers}
      enqueue_persistence(state, tracked.key, :routine, value(config, :kind), attrs)
    else
      state
    end
  end

  defp webhook_completion_status(config, "completed", event) do
    delivery = value(config, :delivery, %{})

    if value(config, :automation_contract_version) === 1 and value(delivery, :mode) == "webhook" do
      payload = value(event, :payload, %{})

      case value(payload, :automation_completion_status) do
        "succeeded" -> "completed"
        "failed" -> "failed"
        _ -> "unknown_outcome"
      end
    else
      "completed"
    end
  end

  defp webhook_completion_status(_config, status, _event), do: status

  defp typed_outcome(config, context, "completed", started_at) do
    schedule = value(config, :schedule)

    cond do
      value(context, :advance) != true ->
        {%{}, parse_datetime(value(context, :preserved_next_run_at))}

      value(schedule, :kind) == "at" ->
        if value(config, :deleteAfterRun, true),
          do: {%{"__delete_after_run" => true}, nil},
          else: {%{"enabled" => false}, nil}

      value(schedule, :kind) == "every" ->
        candidate = DateTime.add(started_at, value(schedule, :everyMs), :millisecond)

        next =
          if DateTime.compare(candidate, DateTime.utc_now()) == :gt,
            do: candidate,
            else: computed_next(config)

        {%{}, next}

      true ->
        {%{}, computed_next(config)}
    end
  end

  defp typed_outcome(_config, context, _status, _started_at),
    do: {%{}, parse_datetime(value(context, :preserved_next_run_at))}

  defp computed_next(config) do
    case Schedule.next_after(
           value(config, :schedule),
           value(config, :timezone),
           DateTime.utc_now(),
           value(config, :id)
         ) do
      {:ok, next} -> next
      :none -> nil
      {:error, _} -> nil
    end
  end

  defp routine_state(config, status, last_run_at, next_run_at) do
    %{"id" => value(config, :id)}
    |> Map.put("last_run_at", encode_datetime(last_run_at))
    |> Map.put("last_status", status)
    |> Map.put("next_run_at", encode_datetime(next_run_at))
  end

  defp track_trigger(
         state,
         key,
         config,
         {:ok, %Synapsis.AgentRun{id: run_id} = run},
         last_run_at,
         next_run_at
       )
       when is_binary(run_id) do
    RunEvents.publish_routine_triggered(config, run)

    tracked = %{
      key: key,
      config: config,
      last_run_at: run.started_at || last_run_at,
      next_run_at: next_run_at
    }

    cond do
      retirement_identity_pending?(state, key) ->
        state = put_in(state.tracked_runs[run_id], tracked)

        if run.status in ~w(completed failed cancelled interrupted timed_out unknown_outcome) do
          hold_terminal_event(state, run_id, run.status, %{
            payload: terminal_run_payload(run)
          })
        else
          state
        end

      typed_schedule?(config) and
          run.status in ~w(completed failed cancelled interrupted timed_out unknown_outcome) ->
        persist_terminal(state, tracked, run.status, %{
          payload: terminal_run_payload(run)
        })

      true ->
        case Map.pop(state.terminal_events, run_id) do
          {nil, terminal_events} ->
            %{
              state
              | tracked_runs: Map.put(state.tracked_runs, run_id, tracked),
                terminal_events: terminal_events
            }

          {:persisted, _terminal_events} ->
            state

          {%{status: status, payload: payload}, terminal_events} ->
            state
            |> Map.put(:terminal_events, terminal_events)
            |> put_terminal_event(run_id, :persisted)
            |> persist_terminal(tracked, status, payload)

          {_unexpected, terminal_events} ->
            %{state | terminal_events: terminal_events}
        end
    end
  end

  defp track_trigger(state, key, _config, {:error, reason}, last_run_at, _next_run_at) do
    status = %{
      last_run_at: encode_datetime(last_run_at),
      last_status: "error",
      last_error: bounded_error(reason)
    }

    %{state | trigger_results: Map.put(state.trigger_results, key, status)}
  end

  defp track_trigger(state, key, _config, _result, last_run_at, _next_run_at) do
    put_trigger_error(
      state,
      key,
      {:unexpected_trigger_result, encode_datetime(last_run_at)}
    )
  end

  defp terminal_run_payload(run) do
    {completion, truncated} = Synapsis.RoutineRuns.completion_projection(run)

    payload =
      Map.merge(%{started_at: encode_datetime(run.started_at), error: run.error}, completion)

    if map_size(truncated) > 0, do: Map.put(payload, :truncated, truncated), else: payload
  end

  defp handle_terminal_event(state, run_id, status, payload) do
    cond do
      MapSet.member?(state.retired_run_ids, run_id) ->
        accept_retired_run_ids(state, [run_id])

      terminal_identity_pending?(state, state.tracked_runs[run_id], payload) ->
        hold_terminal_event(state, run_id, status, payload)

      true ->
        apply_terminal_event(state, run_id, status, payload)
    end
  end

  defp apply_terminal_event(state, run_id, status, payload) do
    case Map.pop(state.tracked_runs, run_id) do
      {nil, tracked_runs} ->
        state
        |> Map.put(:tracked_runs, tracked_runs)
        |> reconcile_terminal_event(run_id, status, payload)

      {tracked, tracked_runs} ->
        state
        |> Map.put(:tracked_runs, tracked_runs)
        |> put_terminal_event(run_id, :persisted)
        |> persist_terminal(tracked, status, payload)
    end
  end

  defp reconcile_terminal_event(state, run_id, status, payload) do
    cond do
      MapSet.member?(state.retired_run_ids, run_id) ->
        state

      Map.get(state.terminal_events, run_id) == :persisted ->
        state

      terminal_side_effects_held?(state, payload) ->
        put_terminal_event(state, run_id, %{status: status, payload: payload})

      true ->
        case terminal_event_tracking(state, payload) do
          {:ok, tracked} ->
            state
            |> put_terminal_event(run_id, :persisted)
            |> persist_terminal(tracked, status, payload)

          :error ->
            state
        end
    end
  end

  defp terminal_side_effects_held?(state, %{payload: payload}) do
    ref = value(payload, :automation_ref)

    target =
      if is_map(ref), do: {value(ref, :source), value(ref, :id)}, else: nil

    producers = Map.values(state.trigger_tasks) ++ Map.values(state.unresolved_producers)

    case target do
      {source, id} when source in ["routine", "heartbeat"] and is_binary(id) ->
        Enum.any?(producers, &(&1.key == target))

      _unclassified ->
        # Missing source evidence cannot establish that this is fresh work.
        id = value(payload, :routine_id)

        Enum.any?(producers, fn task ->
          task.retired and is_tuple(task.key) and elem(task.key, 1) == id
        end)
    end
  end

  defp terminal_side_effects_held?(_state, _payload), do: false

  defp terminal_event_tracking(state, %{kind: kind, payload: payload}) when is_map(payload) do
    routine_id = Map.get(payload, :routine_id, Map.get(payload, "routine_id"))

    with config when not is_nil(config) <-
           matching_config(state.configs, routine_id, kind, payload),
         %DateTime{} = last_run_at <- terminal_started_at(payload) do
      key = routine_key(config)

      {:ok,
       %{
         key: key,
         config: restore_schedule_context(config, value(payload, :routine_schedule)),
         last_run_at: last_run_at,
         next_run_at: get_in(state.timers, [key, :next_run_at])
       }}
    else
      _unmatched -> :error
    end
  end

  defp terminal_event_tracking(_state, _payload), do: :error

  defp matching_config(configs, routine_id, kind, payload) when is_binary(routine_id) do
    candidates =
      Enum.filter(configs, fn config ->
        value(config, :id) == routine_id and value(config, :kind, "heartbeat") == kind
      end)

    candidates =
      case value(payload, :automation_ref) do
        nil ->
          candidates

        reference when is_map(reference) ->
          source = value(reference, :source)

          if source in ["routine", "heartbeat"] and value(reference, :id) == routine_id,
            do: Enum.filter(candidates, &(config_source(&1) == source)),
            else: []

        _invalid_reference ->
          []
      end

    case candidates do
      [config] -> config
      _unmatched_or_ambiguous -> nil
    end
  end

  defp matching_config(_configs, _routine_id, _kind, _payload), do: nil

  defp terminal_started_at(payload) do
    payload
    |> Map.get(:started_at, Map.get(payload, "started_at"))
    |> parse_datetime()
    |> case do
      %DateTime{} = datetime -> datetime
      nil -> payload |> Map.get(:inserted_at, Map.get(payload, "inserted_at")) |> parse_datetime()
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp put_terminal_event(state, run_id, event) do
    %{state | terminal_events: put_bounded_terminal(state.terminal_events, run_id, event)}
  end

  defp persist_terminal(state, %{retired: true}, _status, _payload), do: state

  defp persist_terminal(state, tracked, status, payload) do
    if typed_schedule?(tracked.config) do
      persist_typed_terminal(state, tracked, status, payload)
    else
      persist_legacy_terminal(state, tracked, status, payload)
    end
  end

  defp persist_legacy_terminal(state, tracked, status, payload) do
    attrs =
      routine_state(tracked.config, status, tracked.last_run_at, tracked.next_run_at)
      |> schedule_guard(tracked.config)

    observable = %{
      last_run_at: attrs["last_run_at"],
      last_status: status,
      last_error: terminal_error(payload)
    }

    state = %{
      state
      | trigger_results: Map.put(state.trigger_results, tracked.key, observable),
        terminal_results: Map.put(state.terminal_results, tracked.key, observable)
    }

    enqueue_persistence(
      state,
      tracked.key,
      config_type(tracked.config),
      value(tracked.config, :kind, "heartbeat"),
      attrs
    )
  end

  defp persist_next_run(state, config, next_run_at) do
    attrs = %{
      "id" => value(config, :id),
      "next_run_at" => encode_datetime(next_run_at)
    }

    attrs = schedule_guard(attrs, config)

    enqueue_persistence(
      state,
      routine_key(config),
      config_type(config),
      value(config, :kind, "heartbeat"),
      attrs
    )
  end

  defp enqueue_persistence(state, key, type, kind, attrs) do
    previous = Map.get(state.persistence_snapshots, key, %{})

    previous =
      if Map.take(previous, ["__schedule_generation", "__schedule_fingerprint"]) ==
           Map.take(attrs, ["__schedule_generation", "__schedule_fingerprint"]),
         do: Map.take(previous, ["id", "last_run_at", "last_status"]),
         else: %{}

    attrs = Map.merge(previous, attrs)

    state =
      state
      |> cancel_persistence_retry(key)
      |> put_in([:persistence_snapshots, key], attrs)

    if persistence_active?(state, key) do
      put_in(state.pending_persistence[key], %{type: type, kind: kind, attrs: attrs})
    else
      start_persistence_task(state, key, type, kind, attrs)
    end
  end

  defp persistence_active?(state, key) do
    Enum.any?(state.persistence_tasks, fn {_ref, task} -> task.key == key end)
  end

  defp start_persistence_task(state, key, type, kind, attrs, attempt \\ 0) do
    writer = state.config_writer

    try do
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          protect(fn -> writer.(type, attrs) end)
        end)

      timeout_ref =
        Process.send_after(
          self(),
          {:persistence_timeout, task.ref, task.pid},
          state.trigger_timeout_ms
        )

      tracked = %{
        pid: task.pid,
        monitor: task.ref,
        key: key,
        type: type,
        kind: kind,
        attrs: attrs,
        attempt: attempt,
        timeout_ref: timeout_ref
      }

      %{state | persistence_tasks: Map.put(state.persistence_tasks, task.ref, tracked)}
    rescue
      error -> put_trigger_error(state, key, {:config_persist_task_start_failed, error})
    catch
      :exit, reason ->
        put_trigger_error(state, key, {:config_persist_task_start_failed, reason})
    end
  end

  defp finish_persistence_task(state, ref, %{retired: true} = task, _result) do
    state
    |> Map.put(:persistence_tasks, Map.delete(state.persistence_tasks, ref))
    |> start_pending_persistence(task.key)
  end

  defp finish_persistence_task(state, ref, task, result) do
    state =
      state
      |> Map.put(:persistence_tasks, Map.delete(state.persistence_tasks, ref))
      |> apply_persistence_result(task, result)

    cond do
      persistence_success?(result) ->
        if task.attrs["__materialize"] || task.attrs["__schedule_generation"] ||
             task.attrs["__schedule_fingerprint"],
           do: send(self(), :check_due_routines)

        RunEvents.publish_routine_updated(%{
          "id" => task.attrs["id"],
          "source" => Atom.to_string(task.type),
          "kind" => persisted_kind(result, task.kind)
        })

        start_pending_persistence(state, task.key)

      result in [{:error, :stale_schedule}, {:error, :not_found}] ->
        start_pending_persistence(state, task.key)

      Map.has_key?(state.pending_persistence, task.key) ->
        start_pending_persistence(state, task.key)

      true ->
        schedule_persistence_retry(state, task)
    end
  end

  defp start_pending_persistence(state, key) do
    case Map.pop(state.pending_persistence, key) do
      {nil, pending_persistence} ->
        %{state | pending_persistence: pending_persistence}

      {%{type: type, kind: kind, attrs: attrs}, pending_persistence} ->
        state
        |> Map.put(:pending_persistence, pending_persistence)
        |> start_persistence_task(key, type, kind, attrs)
    end
  end

  defp schedule_persistence_retry(state, task)
       when task.attempt < state.persistence_retry_limit do
    attempt = task.attempt + 1
    delay = state.persistence_retry_backoff_ms * :erlang.bsl(1, attempt - 1)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_persistence, task.key, token}, delay)

    retry = %{
      token: token,
      timer_ref: timer_ref,
      type: task.type,
      kind: task.kind,
      attrs: Map.get(state.persistence_snapshots, task.key, task.attrs),
      attempt: attempt
    }

    put_in(state.persistence_retry_timers[task.key], retry)
  end

  defp schedule_persistence_retry(state, _task), do: state

  defp cancel_persistence_retry(state, key) do
    case Map.pop(state.persistence_retry_timers, key) do
      {nil, persistence_retry_timers} ->
        %{state | persistence_retry_timers: persistence_retry_timers}

      {%{timer_ref: timer_ref}, persistence_retry_timers} ->
        cancel_timeout(timer_ref)
        %{state | persistence_retry_timers: persistence_retry_timers}
    end
  end

  defp persistence_success?(:ok), do: true
  defp persistence_success?({:ok, _value}), do: true
  defp persistence_success?(_result), do: false

  defp persisted_kind({:ok, persisted}, fallback) when is_map(persisted),
    do: value(persisted, :kind, fallback)

  defp persisted_kind(_result, fallback), do: fallback

  defp apply_persistence_result(state, task, :ok), do: restore_terminal_result(state, task)

  defp apply_persistence_result(state, task, {:ok, _value}),
    do: restore_terminal_result(state, task)

  defp apply_persistence_result(state, _task, {:error, reason})
       when reason in [:stale_schedule, :not_found],
       do: state

  defp apply_persistence_result(state, task, {:error, reason}),
    do: put_trigger_error(state, task.key, {:config_persist_failed, reason})

  defp apply_persistence_result(state, task, other),
    do: put_trigger_error(state, task.key, {:unexpected_config_persist_result, other})

  defp restore_terminal_result(state, %{key: key, attrs: %{"last_status" => _status}}) do
    case Map.fetch(state.terminal_results, key) do
      {:ok, observable} ->
        %{state | trigger_results: Map.put(state.trigger_results, key, observable)}

      :error ->
        state
    end
  end

  defp restore_terminal_result(state, _task), do: state

  defp put_trigger_error(state, key, reason) do
    status = %{
      last_run_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      last_status: "error",
      last_error: bounded_error(reason)
    }

    Logger.warning("heartbeat_trigger_failed", routine_id: key, reason: status.last_error)
    %{state | trigger_results: Map.put(state.trigger_results, key, status)}
  end

  defp trigger_context(state, next_run_at) do
    %{
      daemon: state.daemon,
      trigger_fun: state.trigger_fun,
      config_writer: state.config_writer,
      next_run_at: next_run_at
    }
  end

  defp delete_trigger_task(state, key),
    do: %{state | trigger_tasks: Map.delete(state.trigger_tasks, key)}

  defp cancel_trigger_task_tracking(task) do
    Process.unlink(task.pid)
    Process.demonitor(task.monitor, [:flush])
    cancel_timeout(task.timeout_ref)
  end

  defp cancel_persistence_task_tracking(task) do
    Process.demonitor(task.monitor, [:flush])
    cancel_timeout(task.timeout_ref)
  end

  defp cancel_timeout(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timeout(_ref), do: :ok

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp positive_timeout(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(_value), do: nil

  defp same_datetime?(value, %DateTime{} = datetime) when is_binary(value),
    do: value == DateTime.to_iso8601(datetime)

  defp same_datetime?(%DateTime{} = value, %DateTime{} = datetime),
    do: DateTime.compare(value, datetime) == :eq

  defp same_datetime?(_value, _datetime), do: false

  defp config_type(config) do
    case value(config, :__config_type) do
      "routine" ->
        :routine

      "heartbeat" ->
        :heartbeat

      _unknown ->
        if value(config, :kind, "heartbeat") == "heartbeat", do: :heartbeat, else: :routine
    end
  end

  defp merge_config(type, %{"id" => id} = attrs) do
    generation = attrs["__schedule_generation"]

    patch =
      Map.drop(attrs, [
        "id",
        "__schedule_generation",
        "__schedule_fingerprint",
        "__delete_after_run",
        "__materialize"
      ])

    cond do
      attrs["__materialize"] ->
        ConfigStore.merge_existing(type, id, %{})

      attrs["__delete_after_run"] ->
        ConfigStore.delete_routine_schedule(type, id, generation)

      is_binary(generation) ->
        ConfigStore.merge_routine_schedule(type, id, generation, patch)

      Map.has_key?(attrs, "__schedule_fingerprint") ->
        ConfigStore.merge_routine_schedule(
          type,
          id,
          {:legacy_cadence, attrs["__schedule_fingerprint"]},
          patch
        )

      true ->
        ConfigStore.merge_existing(type, id, patch)
    end
  end

  defp terminal_error(%{status: "failed", payload: payload}) when is_map(payload),
    do: Map.get(payload, :error, Map.get(payload, "error"))

  defp terminal_error(_payload), do: nil

  defp put_bounded_terminal(events, run_id, payload) when map_size(events) >= 100,
    do: %{run_id => payload}

  defp put_bounded_terminal(events, run_id, payload), do: Map.put(events, run_id, payload)

  defp bounded_error(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp routine_options(config) do
    kind = value(config, :kind, "schedule")
    allow_todo_write = value(config, :allow_todo_write, false) == true

    options = %{
      routine_id: value(config, :id),
      idempotency_key: value(config, :__idempotency_key),
      scheduled_for: value(config, :__scheduled_for),
      prompt: value(config, :prompt),
      assistant_name: value(config, :agent_name, "main") || "main",
      tool_profile: routine_tool_profile(config, kind, allow_todo_write),
      allow_todo_write: allow_todo_write,
      no_overlap: value(config, :no_overlap, true) != false,
      max_runtime_ms: value(config, :max_runtime_ms, :timer.minutes(2)),
      metadata: automation_metadata(config)
    }

    if value(config, :automation_contract_version) == 1,
      do: Map.merge(options, %{provider: value(config, :provider), model: value(config, :model)}),
      else: options
  end

  defp automation_metadata(config) do
    metadata = %{"routine_name" => value(config, :name)}

    metadata =
      if context = value(config, :__schedule_context),
        do: Map.put(metadata, "routine_schedule", context),
        else: metadata

    source = value(config, :__config_type)
    id = value(config, :id)

    metadata =
      if source in ["routine", "heartbeat"] and match?({:ok, ^id}, Ecto.UUID.cast(id)),
        do: Map.put(metadata, "automation_ref", %{"source" => source, "id" => id}),
        else: metadata

    Synapsis.Agent.Automation.Execution.metadata(config, metadata)
  end

  defp routine_tool_profile(config, "dream", allow_todo_write) do
    case value(config, :tool_profile) do
      profile when profile in ["native_agent", "assistant_dream", "assistant_dream_todo"] ->
        profile

      _profile ->
        if allow_todo_write, do: "assistant_dream_todo", else: "assistant_dream"
    end
  end

  defp routine_tool_profile(config, _kind, _allow_todo_write),
    do: value(config, :tool_profile, "assistant_basic") || "assistant_basic"

  defp resolve_config(configs, {source, id} = target)
       when source in ["routine", "heartbeat"] and is_binary(id) do
    configs
    |> Enum.filter(&(routine_key(&1) == target))
    |> resolve_unique()
  end

  defp resolve_config(configs, identifier) when is_binary(identifier) do
    case Enum.filter(configs, &(value(&1, :id) == identifier)) do
      [] -> configs |> Enum.filter(&(value(&1, :name) == identifier)) |> resolve_unique()
      candidates -> resolve_unique(candidates)
    end
  end

  defp resolve_config(_configs, _identifier), do: {:error, :not_found}

  defp resolve_unique([config]), do: {:ok, config}
  defp resolve_unique([]), do: {:error, :not_found}
  defp resolve_unique(_ambiguous), do: {:error, :ambiguous}

  defp config_by_id(configs, key), do: Enum.find(configs, &(routine_key(&1) == key))

  defp routine_key(config) do
    case config_source(config) do
      nil -> value(config, :id)
      source -> {source, value(config, :id)}
    end
  end

  defp config_source(config) do
    case value(config, :__config_type) do
      source when source in ["routine", "heartbeat"] -> source
      _unattributed -> nil
    end
  end

  defp fail_close_target?(config, {source, id}) when source in ["routine", "heartbeat"],
    do: value(config, :id) == id and config_source(config) in [nil, source]

  defp fail_close_target?(config, id) when is_binary(id), do: value(config, :id) == id
  defp fail_close_target?(_config, _target), do: false

  defp cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_timer), do: :ok

  defp value(config, key, default \\ nil) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end
end
