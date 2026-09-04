defmodule Synapsis.Agent.Routine.Runner do
  @moduledoc """
  Fire path for a claimed routine occurrence: Daemon.trigger → await → finalize.
  """

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Heartbeat.Delivery
  alias Synapsis.Agent.Routine.{Definition, Occurrence, State}
  alias Synapsis.Agent.Runs
  alias Synapsis.AgentRun
  require Logger

  @await_poll_ms 100
  @default_await_ms :timer.minutes(10)

  @spec execute(Definition.t(), Occurrence.t(), keyword()) :: :ok | {:error, term()}
  def execute(%Definition{} = defn, %{} = occurrence, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- check_no_overlap(defn, occurrence),
         {:ok, claimed} <- Occurrence.claim(defn.id, occurrence.occurrence_key, now: now),
         {:ok, run} <- trigger(defn, claimed, opts),
         {:ok, started} <- Occurrence.mark_started(claimed, run.id, now: now) do
      _ = maybe_touch_started(defn.id, run.id, now)
      await_and_finalize(defn, started, run.id, opts)
    else
      {:error, :overlap} = err ->
        _ =
          Occurrence.mark_skipped(defn.id, occurrence.occurrence_key, "no_overlap",
            now: now,
            scheduled_for: occurrence.scheduled_for
          )

        err

      {:error, {:already_active, _}} = err ->
        err

      {:error, {:already_terminal, _}} = err ->
        err

      {:error, reason} = err ->
        Logger.warning("routine_runner_failed",
          routine_id: defn.id,
          occurrence_key: occurrence.occurrence_key,
          reason: inspect(reason)
        )

        _ =
          Occurrence.mark_finished(occurrence.occurrence_key, "failed",
            now: now,
            error: inspect(reason),
            outcome: "failed"
          )

        _ = State.record_failure(defn.id, inspect(reason), retry_policy: defn.retry_policy)
        err
    end
  end

  @doc "Reconcile a stuck claimed/running occurrence when no coordinator is alive."
  @spec reconcile_occurrence(Occurrence.t(), keyword()) ::
          {:ok, Occurrence.t()} | {:error, term()}
  def reconcile_occurrence(occ, opts \\ [])

  def reconcile_occurrence(%{status: status} = occ, opts)
      when status in ~w(claimed running) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    alive? = Keyword.get(opts, :alive?, false)

    cond do
      alive? ->
        {:ok, occ}

      is_binary(occ.run_id) ->
        case Runs.get(occ.run_id) do
          %AgentRun{} = run ->
            if AgentRun.terminal?(run) do
              status = map_run_status(run.status)

              Occurrence.mark_finished(occ, status,
                now: now,
                run_id: run.id,
                outcome: status,
                error: run.error
              )
            else
              # No live coordinator — mark failed without side-effect replay
              case Synapsis.Agent.RunReconciler.classify(run, %{alive?: false, now: now}) do
                {:reconcile, recon_status, payload} ->
                  _ =
                    case recon_status do
                      "timed_out" -> Runs.mark_timed_out(run, payload)
                      "unknown_outcome" -> Runs.mark_unknown_outcome(run, payload)
                      _ -> Runs.mark_failed(run, payload["error"] || "reconciled", payload)
                    end

                  Occurrence.mark_finished(occ, recon_status,
                    now: now,
                    run_id: run.id,
                    outcome: recon_status,
                    error: payload["error"]
                  )

                {:keep, _} ->
                  {:ok, occ}
              end
            end

          nil ->
            Occurrence.mark_finished(occ, "failed",
              now: now,
              outcome: "failed",
              error: "run missing after restart"
            )
        end

      true ->
        # Claimed but never started a run — fail closed, no side effects
        Occurrence.mark_finished(occ, "failed",
          now: now,
          outcome: "failed",
          error: "claimed without run after restart"
        )
    end
  end

  def reconcile_occurrence(occ, _opts), do: {:ok, occ}

  defp check_no_overlap(%Definition{no_overlap: false}, _occ), do: :ok

  defp check_no_overlap(%Definition{id: id, no_overlap: true}, occ) do
    active =
      id
      |> Occurrence.list_active()
      |> Enum.reject(&(&1.occurrence_key == occ.occurrence_key))

    active_run? =
      Runs.list_recent(limit: 50)
      |> Enum.any?(fn run ->
        not AgentRun.terminal?(run) and
          (run.routine_id == id or run.heartbeat_id == id)
      end)

    if active != [] or active_run?, do: {:error, :overlap}, else: :ok
  end

  defp trigger(%Definition{} = defn, claimed, opts) do
    trigger_opts = %{
      prompt: defn.prompt || "",
      agent: defn.agent_name || "main",
      assistant_name: defn.agent_name || "main",
      heartbeat_id: defn.id,
      routine_id: defn.id,
      name: defn.name,
      keep_history: defn.keep_history,
      notify_user: defn.notify_user,
      provider: Keyword.get(opts, :provider) || defn.provider,
      model: Keyword.get(opts, :model) || defn.model,
      deadline_at: deadline(defn, Keyword.get(opts, :now, DateTime.utc_now())),
      idempotency_key: claimed.occurrence_key,
      metadata: %{
        "routine_name" => defn.name,
        "occurrence_key" => claimed.occurrence_key,
        "type" => Atom.to_string(defn.kind)
      }
    }

    case defn.kind do
      :heartbeat -> Daemon.trigger(:heartbeat, defn.id, trigger_opts)
      other -> {:error, {:kind_not_implemented, other}}
    end
  end

  defp await_and_finalize(defn, occurrence, run_id, opts) do
    timeout_ms = defn.max_runtime_ms || Keyword.get(opts, :await_ms, @default_await_ms)

    case await_terminal(run_id, timeout_ms) do
      {:ok, %AgentRun{} = run} ->
        status = map_run_status(run.status)

        _ =
          Occurrence.mark_finished(occurrence, status,
            run_id: run.id,
            outcome: status,
            error: run.error
          )

        _ =
          if status == "completed" do
            State.record_success(defn.id, run.id)
          else
            State.record_failure(defn.id, run.error || status,
              run_id: run.id,
              retry_policy: defn.retry_policy
            )
          end

        outcome = if status == "completed", do: :completed, else: :failed
        _ = Daemon.record_heartbeat_outcome(defn.id, outcome, finished_at: run.finished_at)

        if defn.kind == :heartbeat do
          _ = Delivery.deliver(run, Definition.to_heartbeat_config(defn))
        end

        if status == "completed", do: :ok, else: {:error, run.error || status}

      {:error, :await_timeout} ->
        _ =
          Occurrence.mark_finished(occurrence, "timed_out",
            run_id: run_id,
            outcome: "timed_out",
            error: "await_timeout"
          )

        _ =
          State.record_failure(defn.id, "await_timeout",
            run_id: run_id,
            retry_policy: defn.retry_policy
          )

        _ = Daemon.record_heartbeat_outcome(defn.id, :failed)
        {:error, :await_timeout}
    end
  end

  defp await_terminal(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(run_id, deadline)
  end

  defp do_await(run_id, deadline) do
    case Runs.get(run_id) do
      %AgentRun{} = run ->
        if AgentRun.terminal?(run) do
          {:ok, run}
        else
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :await_timeout}
          else
            Process.sleep(@await_poll_ms)
            do_await(run_id, deadline)
          end
        end

      nil ->
        {:error, :await_timeout}
    end
  end

  defp map_run_status("completed"), do: "completed"
  defp map_run_status("timed_out"), do: "timed_out"
  defp map_run_status(_), do: "failed"

  defp deadline(%Definition{max_runtime_ms: ms}, now) when is_integer(ms) and ms > 0 do
    DateTime.add(now, ms, :millisecond)
  end

  defp deadline(_, _), do: nil

  defp maybe_touch_started(routine_id, run_id, now) do
    state =
      routine_id
      |> State.get_or_new()
      |> Map.merge(%{last_started_at: now, last_run_id: run_id})

    State.persist(state)
  end
end
