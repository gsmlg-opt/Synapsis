defmodule Synapsis.Agent.Runs do
  @moduledoc """
  Lifecycle API for daemon run records.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_runs/`,
  keyed by id (ADR-006 §10 — cluster form is future work).

  Transitions go through `RunReducer`; critical facts persist via `RunEvents`
  before the run projection is updated. Persist failures never report success.
  """
  alias Concord.Turso, as: KV
  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.Agent.RunEvents
  alias Synapsis.Agent.RunReconciler
  alias Synapsis.Agent.RunReducer
  alias Synapsis.Agent.RunState
  alias Synapsis.AgentRun

  @prefix "coord/agent_runs/"
  @idempotency_prefix "coord/agent_run_idempotency/"

  @updatable_fields ~w(
    kind status source assistant_name project_ref workspace_ref session_id
    heartbeat_id routine_id parent_run_id attempt idempotency_key scheduled_for
    deadline_at prompt tool_profile policy_snapshot capability_snapshot model
    provider summary error failure_class recovery_state started_at finished_at
    last_event_sequence revision metadata
  )a

  @spec create(map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    case Map.get(normalized, :idempotency_key) do
      key when is_binary(key) and key != "" ->
        case get_by_idempotency_key(key) do
          %AgentRun{} = existing -> {:ok, existing}
          nil -> do_create(normalized)
        end

      _ ->
        do_create(normalized)
    end
  end

  @spec get(String.t()) :: AgentRun.t() | nil
  def get(id) do
    case KV.get(@prefix <> id) do
      {:ok, map} -> AgentRun.from_store(map)
      _ -> nil
    end
  end

  @spec list_recent(keyword()) :: [AgentRun.t()]
  def list_recent(opts \\ []) do
    scan() |> recent() |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  @spec list_by_status(String.t(), keyword()) :: [AgentRun.t()]
  def list_by_status(status, opts \\ []) when is_binary(status) do
    scan()
    |> Enum.filter(&(&1.status == status))
    |> recent()
    |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  @spec persist(AgentRun.t()) :: {:ok, AgentRun.t()} | {:error, term()}
  def persist(%AgentRun{} = run) do
    case maybe_inject_put_failure() do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case KV.put(@prefix <> run.id, AgentRun.to_store_map(run)) do
          :ok -> {:ok, run}
          {:ok, _} -> {:ok, run}
          other -> {:error, other}
        end
    end
  end

  @spec apply_event(AgentRun.t(), RunEvent.t()) :: {:ok, AgentRun.t()} | {:error, term()}
  def apply_event(%AgentRun{} = run, %RunEvent{} = event) do
    state = RunState.from_run(run)

    with {:ok, new_state} <- RunReducer.reduce(state, event),
         {:ok, ^event} <- RunEvents.append_critical(run, event) do
      new_run = %{RunState.to_run(new_state) | updated_at: utc_now()}
      persist(new_run)
    end
  end

  @spec mark_starting(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_starting(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.starting", attrs)
  end

  @spec mark_running(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_running(%AgentRun{} = run, attrs \\ %{}) do
    with {:ok, run} <- ensure_starting(run, attrs) do
      transition(run, "run.started", attrs)
    end
  end

  @spec mark_waiting_approval(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_waiting_approval(%AgentRun{} = run, attrs \\ %{}) do
    with {:ok, run} <- ensure_running(run, attrs) do
      transition(run, "run.waiting_approval", attrs)
    end
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

  @spec mark_timed_out(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def mark_timed_out(%AgentRun{} = run, attrs \\ %{}) do
    transition(run, "run.timed_out", attrs)
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
    changeset = AgentRun.changeset(%AgentRun{}, normalized)

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

      with {:ok, run} <- persist(run),
           :ok <- maybe_index_idempotency(run),
           {:ok, run} <- transition(run, "run.created", %{}) do
        {:ok, run}
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
    occurred_at = attr(attrs, :finished_at) || attr(attrs, :started_at) || utc_now()
    sequence = run.last_event_sequence + 1

    payload =
      attrs
      |> Map.take([
        :summary,
        :error,
        :failure_class,
        :status
      ])
      |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, Atom.to_string(k), v) end)
      |> Map.merge(string_payload(attrs))

    event =
      RunEvent.new(type,
        run_id: run.id,
        session_id: run.session_id,
        sequence: sequence,
        occurred_at: occurred_at,
        event_id: attr(attrs, :event_id) || Ecto.UUID.generate(),
        payload: payload
      )

    case apply_event(run, event) do
      {:ok, updated} ->
        merged = maybe_merge_attrs(updated, attrs)
        if merged == updated, do: {:ok, updated}, else: persist(%{merged | updated_at: utc_now()})

      {:error, reason} ->
        {:error, reason}
    end
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

  defp string_payload(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp maybe_index_idempotency(%AgentRun{idempotency_key: key, id: id})
       when is_binary(key) and key != "" do
    case KV.put(@idempotency_prefix <> key, %{"run_id" => id}) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> {:error, other}
    end
  end

  defp maybe_index_idempotency(_run), do: :ok

  defp get_by_idempotency_key(key) do
    case KV.get(@idempotency_prefix <> key) do
      {:ok, %{"run_id" => id}} -> get(id)
      {:ok, %{run_id: id}} -> get(id)
      _ -> nil
    end
  end

  defp maybe_inject_put_failure do
    case Process.get(:synapsis_agent_runs_put_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp scan do
    case KV.prefix_scan(@prefix) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, pairs} ->
        Enum.map(pairs, fn {_k, v} ->
          AgentRun.from_store(Concord.Compression.decompress(v))
        end)

      _ ->
        []
    end
  end

  defp recent(runs), do: Enum.sort_by(runs, & &1.inserted_at, {:desc, DateTime})

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

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(normalize_attrs(attrs), key)

  defp utc_now, do: DateTime.utc_now()
end
