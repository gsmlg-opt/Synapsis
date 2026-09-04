defmodule Synapsis.Agent.Heartbeat.LocalScheduler do
  @moduledoc """
  Node-local cron scheduler for daemon-backed heartbeat runs.

  Enabled configs are loaded from `Config.Store`. Each routine owns one timer;
  restart and reload calculate the next future cron occurrence, so missed runs
  are skipped instead of replayed.
  """

  use GenServer
  require Logger

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Heartbeat.Worker
  alias Synapsis.Config.Store, as: ConfigStore

  @reload_interval_ms :timer.seconds(30)
  @trigger_timeout_ms :timer.seconds(5)
  @persistence_retry_limit 2
  @persistence_retry_backoff_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the enabled heartbeat schedule."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Manually submit a loaded heartbeat through the daemon."
  def trigger(server \\ __MODULE__, name) when is_binary(name) do
    case GenServer.call(server, {:lookup, name}) do
      {:ok, config, context} ->
        last_run_at = DateTime.utc_now()
        result = protect(fn -> context.trigger_fun.(config, context.daemon) end)

        GenServer.cast(
          server,
          {:track_trigger, name, config, result, last_run_at, context.next_run_at}
        )

        result

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      timers: %{},
      configs: [],
      daemon: Keyword.get(opts, :daemon, Daemon),
      task_supervisor: Keyword.get(opts, :task_supervisor, Synapsis.Tool.TaskSupervisor),
      config_loader: Keyword.get(opts, :config_loader, &load_configs/0),
      config_writer: Keyword.get(opts, :config_writer, &ConfigStore.put/2),
      trigger_fun: Keyword.get(opts, :trigger_fun, &execute_config/2),
      runs: Keyword.get(opts, :runs, Synapsis.Agent.Runs),
      trigger_timeout_ms: positive_timeout(opts[:trigger_timeout_ms], @trigger_timeout_ms),
      trigger_tasks: %{},
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
  def handle_call(:status, _from, state) do
    entries =
      state.timers
      |> Enum.map(fn {name, timer} ->
        base = %{name: name, schedule: timer.schedule, next_run_at: timer.next_run_at}
        Map.merge(base, Map.get(state.trigger_results, name, %{}))
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, entries, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    case Enum.find(state.configs, &(value(&1, :name) == name)) do
      nil ->
        {:reply, :error, state}

      config ->
        context = trigger_context(state, get_in(state.timers, [name, :next_run_at]))
        {:reply, {:ok, config, context}, state}
    end
  end

  @impl true
  def handle_cast({:track_trigger, name, config, result, last_run_at, next_run_at}, state) do
    {:noreply, track_trigger(state, name, config, result, last_run_at, next_run_at)}
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
      {:noreply, state}
  end

  def handle_info(:check_due_routines, state) do
    {:noreply, reload_configs(state)}
  rescue
    error ->
      Logger.warning("heartbeat_due_check_failed", reason: Exception.message(error))
      {:noreply, state}
  end

  def handle_info({:fire, name, token}, state) do
    case {state.timers[name], Enum.find(state.configs, &(value(&1, :name) == name))} do
      {%{token: ^token}, config} when not is_nil(config) ->
        Logger.info("heartbeat_firing", name: name)
        timers = state.timers |> Map.delete(name) |> schedule_config(config)

        state =
          state
          |> Map.put(:timers, timers)
          |> persist_next_run(config, get_in(timers, [name, :next_run_at]))

        {:noreply, start_trigger_task(state, name, config, get_in(timers, [name, :next_run_at]))}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      trigger = Enum.find(state.trigger_tasks, fn {_name, task} -> task.monitor == ref end) ->
        {name, task} = trigger
        cancel_trigger_task_tracking(task)
        {config, trigger_result, last_run_at, next_run_at} = result

        state =
          state
          |> delete_trigger_task(name)
          |> track_trigger(name, config, trigger_result, last_run_at, next_run_at)

        {:noreply, state}

      task = Map.get(state.persistence_tasks, ref) ->
        cancel_persistence_task_tracking(task)
        {:noreply, finish_persistence_task(state, ref, task, result)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:trigger_timeout, name, pid}, state) do
    case state.trigger_tasks[name] do
      %{pid: ^pid} = task ->
        Process.exit(pid, :kill)
        cancel_trigger_task_tracking(task)

        {:noreply,
         state
         |> delete_trigger_task(name)
         |> put_trigger_error(name, :trigger_timeout)}

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

  def handle_info({:retry_persistence, name, token}, state) do
    case state.persistence_retry_timers[name] do
      %{token: ^token, type: type, attrs: attrs, attempt: attempt} ->
        state = %{
          state
          | persistence_retry_timers: Map.delete(state.persistence_retry_timers, name)
        }

        {:noreply, start_persistence_task(state, name, type, attrs, attempt)}

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
      trigger = Enum.find(state.trigger_tasks, fn {_name, task} -> task.monitor == monitor end) ->
        {name, task} = trigger
        cancel_timeout(task.timeout_ref)

        {:noreply,
         state
         |> delete_trigger_task(name)
         |> put_trigger_error(name, {:trigger_task_down, reason})}

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

  defp reload_configs(state) do
    configs = state.config_loader.() |> Enum.filter(&(value(&1, :enabled, true) != false))
    timers = reconcile_timers(state.timers, configs)

    state = %{state | timers: timers, configs: configs}

    Enum.reduce(configs, state, fn config, acc ->
      next_run_at = get_in(timers, [value(config, :name), :next_run_at])

      if same_datetime?(value(config, :next_run_at), next_run_at),
        do: acc,
        else: persist_next_run(acc, config, next_run_at)
    end)
  end

  defp reconcile_timers(timers, configs) do
    names = MapSet.new(configs, &value(&1, :name))

    timers =
      Enum.reduce(timers, %{}, fn {name, timer}, kept ->
        config = Enum.find(configs, &(value(&1, :name) == name))

        if config && value(config, :schedule) == timer.schedule do
          Map.put(kept, name, timer)
        else
          cancel_timer(timer)
          kept
        end
      end)

    Enum.reduce(configs, timers, fn config, acc ->
      name = value(config, :name)

      if MapSet.member?(names, name) and Map.has_key?(acc, name),
        do: acc,
        else: schedule_config(acc, config)
    end)
  end

  defp schedule_config(timers, config) do
    name = value(config, :name)
    schedule = value(config, :schedule)

    case next_run(schedule) do
      {:ok, delay_ms, next_run_at} ->
        token = make_ref()
        ref = Process.send_after(self(), {:fire, name, token}, delay_ms)

        Map.put(timers, name, %{
          ref: ref,
          token: token,
          schedule: schedule,
          next_run_at: next_run_at
        })

      {:error, reason} ->
        Logger.warning("heartbeat_schedule_skip", name: name, reason: inspect(reason))
        timers
    end
  end

  defp next_run(schedule) do
    with {:ok, expression} <- Crontab.CronExpression.Parser.parse(schedule),
         now = NaiveDateTime.utc_now(),
         {:ok, next_naive} <- Crontab.Scheduler.get_next_run_date(expression, now) do
      next_run_at = DateTime.from_naive!(next_naive, "Etc/UTC")
      delay_ms = max(DateTime.diff(next_run_at, DateTime.utc_now(), :millisecond), 1_000)
      {:ok, delay_ms, next_run_at}
    else
      {:error, reason} -> {:error, reason}
    end
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

  defp start_trigger_task(state, name, config, next_run_at) do
    if Map.has_key?(state.trigger_tasks, name) do
      put_trigger_error(state, name, :trigger_already_running)
    else
      try do
        context = trigger_context(state, next_run_at)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            last_run_at = DateTime.utc_now()
            result = protect(fn -> context.trigger_fun.(config, context.daemon) end)
            {config, result, last_run_at, context.next_run_at}
          end)

        timeout_ref =
          Process.send_after(self(), {:trigger_timeout, name, task.pid}, state.trigger_timeout_ms)

        task = %{pid: task.pid, monitor: task.ref, timeout_ref: timeout_ref}
        %{state | trigger_tasks: Map.put(state.trigger_tasks, name, task)}
      rescue
        error -> put_trigger_error(state, name, {:trigger_task_start_failed, error})
      catch
        :exit, reason -> put_trigger_error(state, name, {:trigger_task_start_failed, reason})
      end
    end
  end

  defp routine_state(config, status, last_run_at, next_run_at) do
    config
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["__config_type"])
    |> Map.put("last_run_at", encode_datetime(last_run_at))
    |> Map.put("last_status", status)
    |> Map.put("next_run_at", encode_datetime(next_run_at))
  end

  defp track_trigger(state, name, config, {:ok, %{id: run_id}}, last_run_at, next_run_at)
       when is_binary(run_id) do
    tracked = %{
      name: name,
      config: config,
      last_run_at: last_run_at,
      next_run_at: next_run_at
    }

    case Map.pop(state.terminal_events, run_id) do
      {nil, terminal_events} ->
        %{
          state
          | tracked_runs: Map.put(state.tracked_runs, run_id, tracked),
            terminal_events: terminal_events
        }

      {:persisted, _terminal_events} ->
        state

      {payload, terminal_events} when is_map(payload) ->
        state = %{state | terminal_events: terminal_events}
        persist_terminal(state, tracked, payload.status, payload)
    end
  end

  defp track_trigger(state, name, _config, {:error, reason}, last_run_at, _next_run_at) do
    status = %{
      last_run_at: encode_datetime(last_run_at),
      last_status: "error",
      last_error: bounded_error(reason)
    }

    %{state | trigger_results: Map.put(state.trigger_results, name, status)}
  end

  defp track_trigger(state, name, _config, _result, last_run_at, _next_run_at) do
    put_trigger_error(
      state,
      name,
      {:unexpected_trigger_result, encode_datetime(last_run_at)}
    )
  end

  defp handle_terminal_event(state, run_id, status, payload) do
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
      Map.get(state.terminal_events, run_id) == :persisted ->
        state

      true ->
        case durable_terminal_tracking(state, run_id, status) do
          {:ok, tracked} ->
            state
            |> put_terminal_event(run_id, :persisted)
            |> persist_terminal(tracked, status, payload)

          :error ->
            if known_config_run?(state.configs, payload),
              do: put_terminal_event(state, run_id, payload),
              else: state
        end
    end
  end

  defp durable_terminal_tracking(state, run_id, status) do
    with {:ok, run} <- state.runs.fetch(run_id),
         true <- run.status == status,
         config when not is_nil(config) <- matching_config(state.configs, run) do
      name = value(config, :name)

      {:ok,
       %{
         name: name,
         config: config,
         last_run_at: run.started_at || run.inserted_at,
         next_run_at: get_in(state.timers, [name, :next_run_at])
       }}
    else
      _unmatched -> :error
    end
  end

  defp matching_config(configs, run) do
    Enum.find(configs, fn config ->
      value(config, :id) == run.routine_id and
        value(config, :kind, "heartbeat") == run.kind
    end)
  end

  defp put_terminal_event(state, run_id, event) do
    %{state | terminal_events: put_bounded_terminal(state.terminal_events, run_id, event)}
  end

  defp persist_terminal(state, tracked, status, payload) do
    attrs = routine_state(tracked.config, status, tracked.last_run_at, tracked.next_run_at)

    observable = %{
      last_run_at: attrs["last_run_at"],
      last_status: status,
      last_error: terminal_error(payload)
    }

    state = %{
      state
      | trigger_results: Map.put(state.trigger_results, tracked.name, observable),
        terminal_results: Map.put(state.terminal_results, tracked.name, observable)
    }

    enqueue_persistence(state, tracked.name, config_type(tracked.config), attrs)
  end

  defp persist_next_run(state, _config, nil), do: state

  defp persist_next_run(state, config, next_run_at) do
    attrs =
      config
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.drop(["__config_type"])
      |> Map.put("next_run_at", encode_datetime(next_run_at))

    enqueue_persistence(state, value(config, :name), config_type(config), attrs)
  end

  defp enqueue_persistence(state, name, type, attrs) do
    attrs = Map.merge(Map.get(state.persistence_snapshots, name, %{}), attrs)

    state =
      state
      |> cancel_persistence_retry(name)
      |> put_in([:persistence_snapshots, name], attrs)

    if persistence_active?(state, name) do
      put_in(state.pending_persistence[name], %{type: type, attrs: attrs})
    else
      start_persistence_task(state, name, type, attrs)
    end
  end

  defp persistence_active?(state, name) do
    Enum.any?(state.persistence_tasks, fn {_ref, task} -> task.name == name end)
  end

  defp start_persistence_task(state, name, type, attrs, attempt \\ 0) do
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
        name: name,
        type: type,
        attrs: attrs,
        attempt: attempt,
        timeout_ref: timeout_ref
      }

      %{state | persistence_tasks: Map.put(state.persistence_tasks, task.ref, tracked)}
    rescue
      error -> put_trigger_error(state, name, {:config_persist_task_start_failed, error})
    catch
      :exit, reason ->
        put_trigger_error(state, name, {:config_persist_task_start_failed, reason})
    end
  end

  defp finish_persistence_task(state, ref, task, result) do
    state =
      state
      |> Map.put(:persistence_tasks, Map.delete(state.persistence_tasks, ref))
      |> apply_persistence_result(task, result)

    cond do
      persistence_success?(result) ->
        start_pending_persistence(state, task.name)

      Map.has_key?(state.pending_persistence, task.name) ->
        start_pending_persistence(state, task.name)

      true ->
        schedule_persistence_retry(state, task)
    end
  end

  defp start_pending_persistence(state, name) do
    case Map.pop(state.pending_persistence, name) do
      {nil, pending_persistence} ->
        %{state | pending_persistence: pending_persistence}

      {%{type: type, attrs: attrs}, pending_persistence} ->
        state
        |> Map.put(:pending_persistence, pending_persistence)
        |> start_persistence_task(name, type, attrs)
    end
  end

  defp schedule_persistence_retry(state, task)
       when task.attempt < state.persistence_retry_limit do
    attempt = task.attempt + 1
    delay = state.persistence_retry_backoff_ms * :erlang.bsl(1, attempt - 1)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_persistence, task.name, token}, delay)

    retry = %{
      token: token,
      timer_ref: timer_ref,
      type: task.type,
      attrs: Map.get(state.persistence_snapshots, task.name, task.attrs),
      attempt: attempt
    }

    put_in(state.persistence_retry_timers[task.name], retry)
  end

  defp schedule_persistence_retry(state, _task), do: state

  defp cancel_persistence_retry(state, name) do
    case Map.pop(state.persistence_retry_timers, name) do
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

  defp apply_persistence_result(state, task, :ok), do: restore_terminal_result(state, task)

  defp apply_persistence_result(state, task, {:ok, _value}),
    do: restore_terminal_result(state, task)

  defp apply_persistence_result(state, task, {:error, reason}),
    do: put_trigger_error(state, task.name, {:config_persist_failed, reason})

  defp apply_persistence_result(state, task, other),
    do: put_trigger_error(state, task.name, {:unexpected_config_persist_result, other})

  defp restore_terminal_result(state, %{name: name, attrs: %{"last_status" => _status}}) do
    case Map.fetch(state.terminal_results, name) do
      {:ok, observable} ->
        %{state | trigger_results: Map.put(state.trigger_results, name, observable)}

      :error ->
        state
    end
  end

  defp restore_terminal_result(state, _task), do: state

  defp put_trigger_error(state, name, reason) do
    status = %{
      last_run_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      last_status: "error",
      last_error: bounded_error(reason)
    }

    Logger.warning("heartbeat_trigger_failed", name: name, reason: status.last_error)
    %{state | trigger_results: Map.put(state.trigger_results, name, status)}
  end

  defp trigger_context(state, next_run_at) do
    %{
      daemon: state.daemon,
      trigger_fun: state.trigger_fun,
      next_run_at: next_run_at
    }
  end

  defp delete_trigger_task(state, name),
    do: %{state | trigger_tasks: Map.delete(state.trigger_tasks, name)}

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

  defp terminal_error(%{status: "failed", payload: payload}) when is_map(payload),
    do: Map.get(payload, :error, Map.get(payload, "error"))

  defp terminal_error(_payload), do: nil

  defp known_config_run?(configs, %{payload: payload}) when is_map(payload) do
    routine_id = Map.get(payload, :routine_id, Map.get(payload, "routine_id"))
    Enum.any?(configs, &(value(&1, :id) == routine_id))
  end

  defp known_config_run?(_configs, _payload), do: false

  defp put_bounded_terminal(events, run_id, payload) when map_size(events) >= 100,
    do: %{run_id => payload}

  defp put_bounded_terminal(events, run_id, payload), do: Map.put(events, run_id, payload)

  defp bounded_error(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp routine_options(config) do
    kind = value(config, :kind, "schedule")
    allow_todo_write = value(config, :allow_todo_write, false) == true

    %{
      routine_id: value(config, :id),
      prompt: value(config, :prompt),
      assistant_name: value(config, :agent_name, "main") || "main",
      tool_profile: routine_tool_profile(config, kind, allow_todo_write),
      allow_todo_write: allow_todo_write,
      no_overlap: value(config, :no_overlap, true) != false,
      max_runtime_ms: value(config, :max_runtime_ms, :timer.minutes(2)),
      metadata: %{"routine_name" => value(config, :name)}
    }
  end

  defp routine_tool_profile(config, "dream", allow_todo_write) do
    case value(config, :tool_profile) do
      profile when profile in ["assistant_dream", "assistant_dream_todo"] -> profile
      _profile -> if allow_todo_write, do: "assistant_dream_todo", else: "assistant_dream"
    end
  end

  defp routine_tool_profile(config, _kind, _allow_todo_write),
    do: value(config, :tool_profile, "assistant_basic") || "assistant_basic"

  defp cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_timer), do: :ok

  defp value(config, key, default \\ nil) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end
end
