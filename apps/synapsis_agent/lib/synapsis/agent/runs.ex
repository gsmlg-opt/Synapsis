defmodule Synapsis.Agent.Runs do
  @moduledoc """
  Lifecycle API for daemon run records.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_runs/`,
  keyed by id (ADR-006 §10 — cluster form is future work).

  Transitions go through `RunReducer`; the data store atomically commits the
  critical fact and projection against the expected snapshot.
  """
  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.Agent.RunEvents
  alias Synapsis.Agent.RunReconciler
  alias Synapsis.Agent.RunReducer
  alias Synapsis.Agent.RunState
  alias Synapsis.AgentRun
  alias Synapsis.AgentRun.Store

  @updatable_fields ~w(
    kind status source assistant_name project_ref workspace_ref session_id
    heartbeat_id routine_id parent_run_id attempt idempotency_key scheduled_for
    deadline_at prompt tool_profile policy_snapshot capability_snapshot model
    provider summary error failure_class recovery_state started_at finished_at
    last_event_sequence revision metadata
  )a

  @spec create(map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    # Identity is accepted only at creation. Normalize both key forms before
    # passing attrs to Ecto, which rejects mixed atom/string keys.
    normalized =
      attrs
      |> Map.drop([:id, "id"])
      |> normalize_attrs()
      |> Map.put(:id, Map.get(attrs, :id, Map.get(attrs, "id")))

    case Map.get(normalized, :idempotency_key) do
      key when is_binary(key) and key != "" ->
        case Store.fetch_by_idempotency(key) do
          {:ok, existing} -> {:ok, existing}
          :not_found -> do_create(normalized)
          {:error, _} = error -> error
        end

      _ ->
        do_create(normalized)
    end
  end

  @spec get(String.t()) :: AgentRun.t() | nil
  def get(id) do
    case fetch(id) do
      {:ok, run} -> run
      _ -> nil
    end
  end

  @spec get_by_idempotency_key(String.t()) :: AgentRun.t() | nil
  def get_by_idempotency_key(key) when is_binary(key) do
    case Store.fetch_by_idempotency(key) do
      {:ok, run} -> run
      _ -> nil
    end
  end

  @doc "Return a tagged lookup result for controller and coordinator callers."
  @spec fetch(String.t()) :: {:ok, AgentRun.t()} | :not_found | {:error, term()}
  def fetch(id) when is_binary(id), do: Store.fetch(id)

  def list_by_status_result(status, opts \\ []) when is_binary(status) do
    with {:ok, runs} <- Store.list() do
      list = runs |> Enum.filter(&(&1.status == status)) |> recent()
      {:ok, take_limit(list, Keyword.get(opts, :limit, 50))}
    end
  end

  @spec list_recent(keyword()) :: [AgentRun.t()]
  def list_recent(opts \\ []) do
    list = scan() |> recent()
    take_limit(list, Keyword.get(opts, :limit, 50))
  end

  @spec list_by_status(String.t(), keyword()) :: [AgentRun.t()]
  def list_by_status(status, opts \\ []) when is_binary(status) do
    list =
      scan()
      |> Enum.filter(&(&1.status == status))
      |> recent()

    take_limit(list, Keyword.get(opts, :limit, 50))
  end

  @spec persist(AgentRun.t()) :: {:ok, AgentRun.t()} | {:error, term()}
  def persist(%AgentRun{} = run) do
    with :ok <- maybe_inject_put_failure(), do: Store.persist(run)
  end

  @spec apply_event(AgentRun.t(), RunEvent.t()) :: {:ok, AgentRun.t()} | {:error, term()}
  def apply_event(%AgentRun{} = run, %RunEvent{} = event) do
    apply_event(run, event, %{})
  end

  defp apply_event(run, event, attrs) do
    cond do
      event.run_id != run.id ->
        {:error, :run_id_mismatch}

      not RunEvent.critical_run?(event) ->
        {:error, :not_critical}

      event.type == "run.created" ->
        {:error, :creation_event_required}

      true ->
        body = RunEvent.to_map(event)

        case Store.fetch_event(event.event_id) do
          {:ok, ^body, durable} ->
            {:ok, durable}

          {:ok, _other, _run} ->
            {:error, :event_id_conflict}

          {:error, _} = error ->
            error

          :not_found ->
            with {:ok, new_state} <- reduce_new_event(run, event),
                 :ok <- check_write_failures() do
              proposed = new_state |> RunState.to_run() |> maybe_merge_attrs(attrs)
              proposed = %{proposed | updated_at: utc_now()}
              Store.commit(run, proposed, body) |> committed_result(event)
            end
        end
    end
  end

  defp reduce_new_event(run, event) do
    with {:ok, state} <- RunReducer.reduce(RunState.from_run(run), event) do
      if state.run.revision == run.revision + 1,
        do: {:ok, state},
        else: {:error, :incomplete_event}
    end
  end

  @spec mark_starting(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_starting(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.starting", attrs)
  end

  @spec mark_running(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_running(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.started", attrs)
  end

  @spec mark_waiting_approval(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_waiting_approval(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.waiting_approval", attrs)
  end

  @spec mark_completed(AgentRun.t(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_completed(%AgentRun{} = run, summary, attrs \\ %{}) when is_binary(summary) do
    transition(run, "run.completed", Map.put(normalize_attrs(attrs), :summary, summary))
  end

  @spec mark_failed(AgentRun.t(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_failed(%AgentRun{} = run, error, attrs \\ %{}) when is_binary(error) do
    transition(run, "run.failed", Map.put(normalize_attrs(attrs), :error, error))
  end

  @spec mark_cancelled(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_cancelled(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.cancelled", attrs)
  end

  @spec mark_interrupted(AgentRun.t(), String.t() | map()) ::
          {:ok, AgentRun.t()} | {:error, term()}
  def mark_interrupted(%AgentRun{} = run, reason) when is_binary(reason) do
    mark_interrupted(run, %{error: reason, metadata: %{"interruption_reason" => reason}})
  end

  def mark_interrupted(%AgentRun{} = run, attrs) when is_map(attrs) do
    transition(run, "run.interrupted", attrs)
  end

  @spec mark_timed_out(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_timed_out(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.timed_out", attrs)
  end

  @spec mark_unknown_outcome(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_unknown_outcome(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.unknown_outcome", attrs)
  end

  @spec mark_side_effect_intent(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_side_effect_intent(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.side_effect_intent", attrs)
  end

  @spec recover_stale_running_runs(keyword()) :: {non_neg_integer(), nil}
  def recover_stale_running_runs(opts \\ []) do
    older_than = Keyword.get(opts, :older_than, DateTime.add(utc_now(), -3600, :second))
    now = Keyword.get(opts, :now, utc_now())
    alive? = Keyword.get(opts, :alive?, false)

    stale =
      scan()
      |> Enum.filter(fn run ->
        not AgentRun.terminal?(run) and
          DateTime.compare(run.started_at || run.inserted_at || now, older_than) == :lt
      end)

    Enum.each(stale, fn run ->
      case RunReconciler.classify(run, %{alive?: alive?, now: now}) do
        {:keep, _} ->
          :ok

        {:reconcile, status, payload} ->
          type =
            case status do
              "timed_out" -> "run.timed_out"
              "unknown_outcome" -> "run.unknown_outcome"
              _ -> "run.failed"
            end

          _ = transition(run, type, Map.merge(payload, %{"status" => status}))
      end
    end)

    {length(stale), nil}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp do_create(normalized) do
    initial_status = Map.get(normalized, :status, "queued")

    changeset =
      %AgentRun{}
      |> AgentRun.changeset(normalized)
      |> Ecto.Changeset.validate_change(:id, fn :id, id ->
        case Ecto.UUID.cast(id) do
          {:ok, _} -> []
          :error -> [id: "is invalid"]
        end
      end)

    if changeset.valid? do
      now = utc_now()

      run =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> then(
          &%{
            &1
            | id: &1.id || Ecto.UUID.generate(),
              inserted_at: now,
              updated_at: now,
              attempt: &1.attempt || 1,
              revision: &1.revision || 0,
              last_event_sequence: &1.last_event_sequence || 0,
              recovery_state: &1.recovery_state || %{},
              policy_snapshot: &1.policy_snapshot || %{},
              capability_snapshot: &1.capability_snapshot || %{},
              metadata: &1.metadata || %{}
          }
        )

      event =
        RunEvent.new("run.created",
          run_id: run.id,
          session_id: run.session_id,
          sequence: run.last_event_sequence + 1,
          occurred_at: now,
          payload: %{"initial_status" => initial_status}
        )

      with {:ok, state} <- RunReducer.reduce(RunState.from_run(%{run | status: "queued"}), event),
           :ok <- check_write_failures() do
        Store.create(RunState.to_run(state), RunEvent.to_map(event)) |> committed_result(event)
      end
    else
      {:error, changeset}
    end
  end

  defp ensure_starting(%AgentRun{status: "queued"} = run, attrs), do: mark_starting(run, attrs)
  defp ensure_starting(%AgentRun{} = run, _attrs), do: {:ok, run}

  defp ensure_running(%AgentRun{status: status} = run, attrs)
       when status in ~w(queued starting) do
    mark_running(run, attrs)
  end

  defp ensure_running(%AgentRun{} = run, _attrs), do: {:ok, run}

  defp transition(%AgentRun{} = run, type, attrs) when is_binary(type) do
    attrs = normalize_attrs(attrs)

    payload =
      attrs
      |> Map.drop([:event_id, "event_id", :id, "id"])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    # Convenience transitions reuse the original envelope for an explicit retry
    # ID; caller-supplied typed events remain exact, including sequence and time.
    case attr(attrs, :event_id) do
      nil ->
        new_transition(run, type, attrs, payload)

      id ->
        case Store.fetch_event(id) do
          {:ok, %{"run_id" => run_id, "type" => ^type, "payload" => ^payload}, durable}
          when run_id == run.id ->
            {:ok, durable}

          {:ok, _body, _run} ->
            {:error, :event_id_conflict}

          :not_found ->
            new_transition(run, type, attrs, payload)

          {:error, _} = error ->
            error
        end
    end
  end

  defp new_transition(run, type, attrs, payload) do
    # The retry ID belongs to the requested transition, not its prerequisite
    # starting/running events.
    preliminary_attrs = Map.drop(attrs, [:event_id, "event_id"])

    with {:ok, run} <- prepare_transition(run, type, preliminary_attrs) do
      commit_transition(run, type, attrs, payload)
    end
  end

  defp prepare_transition(run, "run.started", attrs), do: ensure_starting(run, attrs)
  defp prepare_transition(run, "run.waiting_approval", attrs), do: ensure_running(run, attrs)
  defp prepare_transition(run, _type, _attrs), do: {:ok, run}

  defp commit_transition(run, type, attrs, payload) do
    occurred_at = attr(attrs, :finished_at) || attr(attrs, :started_at) || utc_now()
    sequence = run.last_event_sequence + 1

    event =
      RunEvent.new(type,
        run_id: run.id,
        session_id: run.session_id,
        sequence: sequence,
        occurred_at: occurred_at,
        event_id: attr(attrs, :event_id) || Ecto.UUID.generate(),
        payload: payload
      )

    apply_event(run, event, attrs)
  end

  defp maybe_merge_attrs(run, attrs) do
    keep =
      Map.take(attrs, [
        :session_id,
        :assistant_name,
        :model,
        :provider,
        :started_at,
        :finished_at,
        :deadline_at,
        :metadata,
        :summary,
        :error,
        :failure_class
      ])

    Map.merge(run, keep)
  end

  defp committed_result({:ok, run, :committed}, event) do
    RunEvents.observe_critical(run, event)
    {:ok, run}
  end

  defp committed_result({:ok, run, :duplicate}, _event), do: {:ok, run}
  defp committed_result({:error, _} = error, _event), do: error

  defp check_write_failures do
    with :ok <- maybe_inject_put_failure() do
      case Process.get(:synapsis_run_events_put_result) do
        {:error, _} = error -> error
        _ -> :ok
      end
    end
  end

  defp maybe_inject_put_failure do
    case Process.get(:synapsis_agent_runs_put_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp scan do
    case Store.list() do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp recent(runs), do: Enum.sort_by(runs, & &1.inserted_at, {:desc, DateTime})

  defp take_limit(list, :all), do: list
  defp take_limit(list, limit) when is_integer(limit) and limit >= 0, do: Enum.take(list, limit)
  defp take_limit(list, _limit), do: Enum.take(list, 50)

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when key in @updatable_fields ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case Enum.find(@updatable_fields, &(Atom.to_string(&1) == key)) do
          nil -> Map.put(acc, key, value)
          field -> Map.put(acc, field, value)
        end

      {:event_id, value}, acc ->
        Map.put(acc, :event_id, value)

      _other, acc ->
        acc
    end)
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp utc_now, do: DateTime.utc_now()
end
