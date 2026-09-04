defmodule Synapsis.Agent.Heartbeat.LocalScheduler do
  @moduledoc """
  Node-local cron scheduler for heartbeats — replaces the Oban-based scheduler.

  Loads enabled heartbeat configs only from `Config.Store` (heartbeats.toml).
  Empty valid config yields an empty schedule; load failures mark the scheduler
  degraded instead of silently falling back to Ecto.
  """

  use GenServer
  require Logger

  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Agent.Heartbeat.Worker, as: HeartbeatWorker

  @check_interval_ms :timer.seconds(30)

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return scheduler snapshot.

  `%{degraded?: boolean, degrade_reason: term() | nil, entries: [map()]}`
  """
  @spec status() :: %{
          degraded?: boolean(),
          degrade_reason: term() | nil,
          entries: [%{name: String.t(), schedule: String.t(), next_run_at: DateTime.t() | nil}]
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    send(self(), :tick)

    {:ok,
     %{
       timers: %{},
       configs: [],
       degraded?: false,
       degrade_reason: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    entries =
      Enum.map(state.timers, fn {name, %{next_run_at: nra, schedule: sched}} ->
        %{name: name, schedule: sched, next_run_at: nra}
      end)

    {:reply,
     %{
       degraded?: state.degraded?,
       degrade_reason: state.degrade_reason,
       entries: entries
     }, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {configs, degraded?, reason} = load_configs()

    removed = Map.keys(state.timers) -- Enum.map(configs, & &1.name)
    Enum.each(removed, fn name -> cancel_timer(state.timers[name]) end)

    new_timers =
      Enum.reduce(configs, %{}, fn config, acc ->
        case schedule_next(config) do
          {:ok, timer_ref, next_run_at} ->
            if old = state.timers[config.name], do: cancel_timer(old)

            Map.put(acc, config.name, %{
              ref: timer_ref,
              next_run_at: next_run_at,
              schedule: config.schedule
            })

          {:error, skip_reason} ->
            Logger.warning("heartbeat_schedule_skip",
              name: config.name,
              reason: inspect(skip_reason)
            )

            acc
        end
      end)

    Process.send_after(self(), :tick, @check_interval_ms)

    {:noreply,
     %{
       state
       | timers: new_timers,
         configs: configs,
         degraded?: degraded?,
         degrade_reason: reason
     }}
  end

  def handle_info({:fire, name}, state) do
    config = Enum.find(state.configs, &(&1.name == name))

    if config do
      Logger.info("heartbeat_firing", name: name)

      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        HeartbeatWorker.execute(config)
      end)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp load_configs do
    file_configs =
      :heartbeat
      |> ConfigStore.list()
      |> Enum.map(fn c ->
        %{
          id: c["id"],
          name: c["name"],
          schedule: c["schedule"],
          enabled: c["enabled"],
          prompt: c["prompt"] || "",
          agent_name: c["agent_name"] || "main",
          keep_history: c["keep_history"] || false,
          notify_user: c["notify_user"] || false
        }
      end)

    enabled =
      Enum.filter(file_configs, fn c ->
        Map.get(c, :enabled, true) != false
      end)

    {enabled, false, nil}
  rescue
    error ->
      Logger.warning("heartbeat_config_load_failed", reason: Exception.message(error))
      {[], true, Exception.message(error)}
  catch
    kind, reason ->
      Logger.warning("heartbeat_config_load_failed", reason: inspect({kind, reason}))
      {[], true, inspect({kind, reason})}
  end

  defp schedule_next(config) do
    case next_run_in_ms(config.schedule) do
      {:ok, delay_ms, next_run_at} ->
        ref = Process.send_after(self(), {:fire, config.name}, delay_ms)
        {:ok, ref, next_run_at}

      {:error, _} = err ->
        err
    end
  end

  defp next_run_in_ms(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, expr} ->
        now = NaiveDateTime.utc_now()

        case Crontab.Scheduler.get_next_run_date(expr, now) do
          {:ok, next_naive} ->
            next_utc = DateTime.from_naive!(next_naive, "Etc/UTC")
            diff_ms = DateTime.diff(next_utc, DateTime.utc_now(), :millisecond)
            delay = max(diff_ms, 1_000)
            {:ok, delay, next_utc}

          {:error, reason} ->
            {:error, {:next_run_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp cancel_timer(%{ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_timer(_), do: :ok
end
