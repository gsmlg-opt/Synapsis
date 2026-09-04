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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the enabled heartbeat schedule."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Manually submit a loaded heartbeat through the daemon."
  def trigger(server \\ __MODULE__, name) when is_binary(name) do
    case GenServer.call(server, {:lookup, name}) do
      {:ok, config, context} ->
        {result, _persist_result, _attrs} = execute_and_persist(config, context)
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
      trigger_timeout_ms: positive_timeout(opts[:trigger_timeout_ms], @trigger_timeout_ms),
      trigger_tasks: %{},
      trigger_results: %{},
      reload_interval_ms: Keyword.get(opts, :reload_interval_ms, @reload_interval_ms)
    }

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
  def handle_info(:tick, state) do
    configs = state.config_loader.() |> Enum.filter(&(value(&1, :enabled, true) != false))
    timers = reconcile_timers(state.timers, configs)
    Process.send_after(self(), :tick, state.reload_interval_ms)
    {:noreply, %{state | timers: timers, configs: configs}}
  rescue
    error ->
      Logger.warning("heartbeat_reload_failed", reason: Exception.message(error))
      Process.send_after(self(), :tick, state.reload_interval_ms)
      {:noreply, state}
  end

  def handle_info({:fire, name, token}, state) do
    case {state.timers[name], Enum.find(state.configs, &(value(&1, :name) == name))} do
      {%{token: ^token}, config} when not is_nil(config) ->
        Logger.info("heartbeat_firing", name: name)
        timers = state.timers |> Map.delete(name) |> schedule_config(config)
        state = %{state | timers: timers}

        {:noreply, start_trigger_task(state, name, config, get_in(timers, [name, :next_run_at]))}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.trigger_tasks, fn {_name, task} -> task.monitor == ref end) do
      {name, task} ->
        cancel_trigger_task_tracking(task)

        {:noreply,
         state
         |> delete_trigger_task(name)
         |> put_trigger_result(name, result)}

      nil ->
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

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.trigger_tasks, fn {_name, task} -> task.monitor == monitor end) do
      {name, task} ->
        cancel_timeout(task.timeout_ref)

        {:noreply,
         state
         |> delete_trigger_task(name)
         |> put_trigger_error(name, {:trigger_task_down, reason})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

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
    ConfigStore.list(:heartbeat) ++ ConfigStore.list(:routine)
  rescue
    _error -> Synapsis.Heartbeats.list_enabled()
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
          Task.Supervisor.async(state.task_supervisor, fn ->
            execute_and_persist(config, context)
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

  defp execute_and_persist(config, context) do
    last_run_at = DateTime.utc_now() |> DateTime.to_iso8601()
    result = protect(fn -> context.trigger_fun.(config, context.daemon) end)
    attrs = routine_state(config, result, last_run_at, context.next_run_at)

    persist_result =
      if value(config, :kind, "heartbeat") in ["schedule", "dream"] do
        protect(fn -> context.config_writer.(:routine, attrs) end)
      else
        :ok
      end

    {result, persist_result, attrs}
  end

  defp routine_state(config, result, last_run_at, next_run_at) do
    config
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("last_run_at", last_run_at)
    |> Map.put("last_status", trigger_status(result))
    |> Map.put("next_run_at", encode_datetime(next_run_at))
  end

  defp trigger_status({:ok, %{status: status}}) when is_binary(status), do: status
  defp trigger_status({:ok, _value}), do: "ok"
  defp trigger_status(_error), do: "error"

  defp put_trigger_result(state, name, {result, persist_result, attrs}) do
    error = trigger_error(result) || persist_error(persist_result)

    status = %{
      last_run_at: attrs["last_run_at"],
      last_status: attrs["last_status"],
      last_error: error
    }

    %{state | trigger_results: Map.put(state.trigger_results, name, status)}
  end

  defp put_trigger_error(state, name, reason) do
    status = %{
      last_run_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      last_status: "error",
      last_error: bounded_error(reason)
    }

    Logger.warning("heartbeat_trigger_failed", name: name, reason: status.last_error)
    %{state | trigger_results: Map.put(state.trigger_results, name, status)}
  end

  defp trigger_error({:error, reason}), do: bounded_error(reason)
  defp trigger_error(_result), do: nil

  defp persist_error({:error, reason}), do: bounded_error({:config_persist_failed, reason})
  defp persist_error(_result), do: nil

  defp trigger_context(state, next_run_at) do
    %{
      daemon: state.daemon,
      trigger_fun: state.trigger_fun,
      config_writer: state.config_writer,
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

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(_value), do: nil

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
