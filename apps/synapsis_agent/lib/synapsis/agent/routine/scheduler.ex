defmodule Synapsis.Agent.Routine.Scheduler do
  @moduledoc """
  Durable node-local routine scheduler.

  Persists `next_run_at` in Concord routine state, claims deterministic
  occurrences before `Daemon.trigger`, and reconciles on boot.

  Heartbeat configs remain the first adapter via `Routine.Definition`.
  """

  use GenServer
  require Logger

  alias Synapsis.Agent.Routine.{Clock, Definition, Occurrence, Runner, Schedule, State}

  @check_interval_ms :timer.seconds(30)
  @default_name Synapsis.Agent.Heartbeat.LocalScheduler

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return scheduler snapshot compatible with LocalScheduler / health controller.

  `%{degraded?: boolean, degrade_reason: term() | nil, entries: [map()]}`
  """
  @spec status(GenServer.server()) :: %{
          degraded?: boolean(),
          degrade_reason: term() | nil,
          entries: [%{name: String.t(), schedule: String.t(), next_run_at: DateTime.t() | nil}]
        }
  def status(server \\ @default_name) do
    GenServer.call(server, :status)
  end

  @doc "Force a reconcile pass (boot / tests)."
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ @default_name) do
    GenServer.call(server, :reconcile)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    state = %{
      timers: %{},
      definitions: %{},
      degraded?: false,
      degrade_reason: nil,
      check_interval_ms: interval,
      reconciled?: false
    }

    send(self(), :boot)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    entries =
      Enum.map(state.definitions, fn {_id, defn} ->
        next =
          case Map.get(state.timers, defn.id) do
            %{next_run_at: nra} ->
              nra

            _ ->
              case State.get(defn.id) do
                %{next_run_at: nra} -> nra
                _ -> nil
              end
          end

        %{name: defn.name, schedule: defn.schedule, next_run_at: next}
      end)

    {:reply,
     %{
       degraded?: state.degraded?,
       degrade_reason: state.degrade_reason,
       entries: entries
     }, state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, do_reconcile(state)}
  end

  @impl true
  def handle_info(:boot, state) do
    state = do_reconcile(state)
    send(self(), :tick)
    {:noreply, %{state | reconciled?: true}}
  end

  def handle_info(:tick, state) do
    {definitions, degraded?, reason} = load_definitions()
    def_map = Map.new(definitions, &{&1.id, &1})

    removed = Map.keys(state.timers) -- Map.keys(def_map)
    Enum.each(removed, fn id -> cancel_timer(state.timers[id]) end)

    now = Clock.now()

    new_timers =
      Enum.reduce(definitions, %{}, fn defn, acc ->
        case ensure_scheduled(defn, Map.get(state.timers, defn.id), now) do
          {:ok, timer_info} ->
            Map.put(acc, defn.id, timer_info)

          {:error, skip_reason} ->
            Logger.warning("routine_schedule_skip",
              routine_id: defn.id,
              reason: inspect(skip_reason)
            )

            acc
        end
      end)

    Process.send_after(self(), :tick, state.check_interval_ms)

    {:noreply,
     %{
       state
       | timers: new_timers,
         definitions: def_map,
         degraded?: degraded?,
         degrade_reason: reason
     }}
  end

  def handle_info({:fire, routine_id, occurrence_key, scheduled_for_iso}, state) do
    case Map.get(state.definitions, routine_id) do
      %Definition{} = defn ->
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          fire(defn, occurrence_key, scheduled_for_iso)
        end)

      nil ->
        Logger.warning("routine_fire_missing_definition", routine_id: routine_id)
    end

    # Drop timer entry so next tick reschedules from durable state
    timers = Map.delete(state.timers, routine_id)
    {:noreply, %{state | timers: timers}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Scheduling ---

  defp load_definitions do
    case Definition.load_heartbeats() do
      {:ok, defs} ->
        {valid, bad} =
          Enum.split_with(defs, fn d ->
            match?({:ok, _}, Crontab.CronExpression.Parser.parse(d.schedule))
          end)

        if bad != [] do
          Logger.warning("routine_bad_schedules",
            count: length(bad),
            ids: Enum.map(bad, & &1.id)
          )
        end

        degraded? = bad != [] and valid == []
        reason = if degraded?, do: :all_schedules_invalid, else: nil
        {valid, degraded?, reason}

      {:error, reason} ->
        Logger.warning("routine_definition_load_failed", reason: inspect(reason))
        {[], true, reason}
    end
  end

  defp ensure_scheduled(%Definition{} = defn, existing_timer, now) do
    state = State.get_or_new(defn.id)

    if State.in_backoff?(state, now) do
      # Keep waiting; schedule a timer for backoff_until if useful
      delay = max(DateTime.diff(state.backoff_until, now, :millisecond), 1_000)

      ref =
        Process.send_after(
          self(),
          {:fire, defn.id, "backoff", DateTime.to_iso8601(state.backoff_until)},
          delay
        )

      if existing_timer, do: cancel_timer(existing_timer)

      {:ok,
       %{ref: ref, next_run_at: state.backoff_until, schedule: defn.schedule, backoff?: true}}
    else
      next =
        cond do
          match?(%DateTime{}, state.next_run_at) and
              DateTime.compare(state.next_run_at, now) == :gt ->
            state.next_run_at

          true ->
            case Schedule.next_after(defn.schedule, defn.timezone, now) do
              {:ok, n} -> n
              {:error, _} -> nil
            end
        end

      case next do
        %DateTime{} = next_run_at ->
          _ = State.put_next_run(defn.id, next_run_at)
          delay = max(DateTime.diff(next_run_at, now, :millisecond), 1_000)
          occ_key = Schedule.occurrence_key(defn.id, next_run_at)

          if existing_timer, do: cancel_timer(existing_timer)

          ref =
            Process.send_after(
              self(),
              {:fire, defn.id, occ_key, DateTime.to_iso8601(next_run_at)},
              delay
            )

          {:ok, %{ref: ref, next_run_at: next_run_at, schedule: defn.schedule}}

        nil ->
          {:error, :no_next_run}
      end
    end
  end

  defp fire(%Definition{}, "backoff", _iso) do
    # Backoff elapsed — tick will reschedule a real occurrence
    :ok
  end

  defp fire(%Definition{} = defn, occurrence_key, scheduled_for_iso) do
    now = Clock.now()

    scheduled_for =
      case DateTime.from_iso8601(scheduled_for_iso) do
        {:ok, dt, _} -> dt
        _ -> now
      end

    # Create scheduled occurrence if absent (idempotent)
    occ = Occurrence.build(defn.id, scheduled_for, status: "scheduled")
    occ = %{occ | occurrence_key: occurrence_key}

    case Occurrence.create_if_absent(occ) do
      {:ok, %{status: status}} when status in ~w(completed failed skipped timed_out) ->
        Logger.info("routine_occurrence_already_terminal",
          routine_id: defn.id,
          occurrence_key: occurrence_key,
          status: status
        )

        advance_after(defn, scheduled_for, now)
        :ok

      {:ok, %{status: status}} when status in ~w(claimed running) ->
        Logger.info("routine_occurrence_already_active",
          routine_id: defn.id,
          occurrence_key: occurrence_key
        )

        :ok

      {:ok, scheduled_occ} ->
        case Runner.execute(defn, scheduled_occ, now: now) do
          :ok ->
            advance_after(defn, scheduled_for, now)

          {:error, :overlap} ->
            advance_after(defn, scheduled_for, now)

          {:error, _} ->
            advance_after(defn, scheduled_for, now)
        end

      {:error, reason} ->
        Logger.error("routine_occurrence_persist_failed",
          routine_id: defn.id,
          reason: inspect(reason)
        )
    end
  end

  defp advance_after(%Definition{} = defn, scheduled_for, now) do
    case Schedule.next_after(defn.schedule, defn.timezone, scheduled_for) do
      {:ok, next} ->
        # If next is still in the past (clock jump), apply misfire on next reconcile/tick
        _ = State.put_next_run(defn.id, next)

      {:error, _} ->
        case Schedule.next_after(defn.schedule, defn.timezone, now) do
          {:ok, next} -> State.put_next_run(defn.id, next)
          _ -> :ok
        end
    end
  end

  # --- Boot reconciliation ---

  defp do_reconcile(state) do
    {definitions, degraded?, reason} = load_definitions()
    def_map = Map.new(definitions, &{&1.id, &1})
    now = Clock.now()

    Enum.each(definitions, fn defn ->
      reconcile_routine(defn, now)
    end)

    %{state | definitions: def_map, degraded?: degraded?, degrade_reason: reason}
  end

  defp reconcile_routine(%Definition{} = defn, now) do
    # 1) Stuck active occurrences
    Enum.each(Occurrence.list_active(defn.id), fn occ ->
      alive? = occurrence_run_alive?(occ)
      _ = Runner.reconcile_occurrence(occ, now: now, alive?: alive?)
    end)

    # 2) Misfire handling for overdue next_run_at
    state = State.get_or_new(defn.id)

    case state.next_run_at do
      %DateTime{} = next ->
        if DateTime.compare(next, now) != :gt do
          apply_misfire(defn, next, now)
        else
          :ok
        end

      nil ->
        case Schedule.next_after(defn.schedule, defn.timezone, now) do
          {:ok, next} -> State.put_next_run(defn.id, next)
          _ -> :ok
        end
    end
  end

  defp apply_misfire(%Definition{misfire_policy: :run_once} = defn, overdue, now) do
    # Skip older missed points; run only the most recent overdue slot once.
    missed = collect_missed(defn, overdue, now)

    case List.last(missed) do
      nil ->
        case Schedule.next_after(defn.schedule, defn.timezone, now) do
          {:ok, next} -> State.put_next_run(defn.id, next)
          _ -> :ok
        end

      latest ->
        Enum.each(missed -- [latest], fn skipped_at ->
          key = Schedule.occurrence_key(defn.id, skipped_at)

          _ =
            Occurrence.mark_skipped(defn.id, key, "misfire_skip",
              now: now,
              scheduled_for: skipped_at
            )
        end)

        occ = Occurrence.build(defn.id, latest, status: "scheduled")

        case Occurrence.create_if_absent(occ) do
          {:ok, %{status: "scheduled"} = o} ->
            _ = Runner.execute(defn, o, now: now)

          {:ok, _} ->
            :ok

          {:error, _} ->
            :ok
        end

        case Schedule.next_after(defn.schedule, defn.timezone, now) do
          {:ok, next} -> State.put_next_run(defn.id, next)
          _ -> :ok
        end
    end
  end

  defp apply_misfire(%Definition{} = defn, overdue, now) do
    # :skip — mark overdue points skipped, schedule next future
    missed = collect_missed(defn, overdue, now)

    Enum.each(missed, fn skipped_at ->
      key = Schedule.occurrence_key(defn.id, skipped_at)

      _ =
        Occurrence.mark_skipped(defn.id, key, "misfire_skip",
          now: now,
          scheduled_for: skipped_at
        )
    end)

    case Schedule.next_after(defn.schedule, defn.timezone, now) do
      {:ok, next} -> State.put_next_run(defn.id, next)
      _ -> :ok
    end
  end

  defp collect_missed(%Definition{} = defn, from, now) do
    do_collect_missed(defn, from, now, [], 0)
  end

  defp do_collect_missed(_defn, _cursor, _now, acc, n) when n > 64, do: Enum.reverse(acc)

  defp do_collect_missed(defn, cursor, now, acc, n) do
    if DateTime.compare(cursor, now) == :gt do
      Enum.reverse(acc)
    else
      acc = [cursor | acc]

      case Schedule.next_after(defn.schedule, defn.timezone, cursor) do
        {:ok, next} ->
          if DateTime.compare(next, cursor) == :gt do
            do_collect_missed(defn, next, now, acc, n + 1)
          else
            Enum.reverse(acc)
          end

        _ ->
          Enum.reverse(acc)
      end
    end
  end

  defp occurrence_run_alive?(%{run_id: run_id}) when is_binary(run_id) do
    case Synapsis.Agent.RunSupervisor.whereis(run_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp occurrence_run_alive?(_), do: false

  defp cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_), do: :ok
end
