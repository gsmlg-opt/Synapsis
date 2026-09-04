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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the enabled heartbeat schedule."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Manually submit a loaded heartbeat through the daemon."
  def trigger(server \\ __MODULE__, name) when is_binary(name) do
    case GenServer.call(server, {:lookup, name}) do
      {:ok, config, daemon} -> Worker.execute(config, daemon)
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      timers: %{},
      configs: [],
      daemon: Keyword.get(opts, :daemon, Daemon),
      task_supervisor: Keyword.get(opts, :task_supervisor, Synapsis.Tool.TaskSupervisor),
      config_loader: Keyword.get(opts, :config_loader, &load_configs/0),
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
        %{name: name, schedule: timer.schedule, next_run_at: timer.next_run_at}
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, entries, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    case Enum.find(state.configs, &(value(&1, :name) == name)) do
      nil -> {:reply, :error, state}
      config -> {:reply, {:ok, config, state.daemon}, state}
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

        case Task.Supervisor.start_child(state.task_supervisor, fn ->
               Worker.execute(config, state.daemon)
             end) do
          {:ok, _pid} -> :ok
          {:error, reason} -> Logger.warning("heartbeat_trigger_failed", reason: inspect(reason))
        end

        timers = state.timers |> Map.delete(name) |> schedule_config(config)
        {:noreply, %{state | timers: timers}}

      _stale ->
        {:noreply, state}
    end
  end

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
    ConfigStore.list(:heartbeat)
  rescue
    _error -> Synapsis.Heartbeats.list_enabled()
  end

  defp cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_timer), do: :ok

  defp value(config, key, default \\ nil) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end
end
