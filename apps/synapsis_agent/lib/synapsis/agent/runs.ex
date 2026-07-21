defmodule Synapsis.Agent.Runs do
  @moduledoc """
  Lifecycle API for daemon run records.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_runs/`,
  keyed by id (ADR-006 §10 — cluster form is future work).
  """
  alias Concord.Turso, as: KV
  alias Synapsis.AgentRun

  @prefix "coord/agent_runs/"
  @stale_error "daemon restarted before completion"
  @updatable_fields ~w(
    kind status source assistant_name session_id heartbeat_id routine_id prompt
    tool_profile model provider summary error started_at finished_at metadata
  )a

  @spec create(map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    changeset = AgentRun.changeset(%AgentRun{}, normalize_attrs(attrs))

    if changeset.valid? do
      now = utc_now()

      run =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> then(&%{&1 | id: &1.id || Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      persist(run)
      {:ok, run}
    else
      {:error, changeset}
    end
  end

  @spec get(String.t()) :: AgentRun.t() | nil
  def get(id) do
    case KV.get(@prefix <> id) do
      {:ok, map} -> struct(AgentRun, map)
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

  @spec mark_running(AgentRun.t(), map()) :: {:ok, AgentRun.t()}
  def mark_running(%AgentRun{} = run, attrs \\ %{}) do
    started_at = attr(attrs, :started_at) || run.started_at || utc_now()
    update_run(run, attrs, %{status: "running", started_at: started_at})
  end

  @spec mark_waiting_approval(AgentRun.t(), map()) :: {:ok, AgentRun.t()}
  def mark_waiting_approval(%AgentRun{} = run, attrs \\ %{}) do
    started_at = attr(attrs, :started_at) || run.started_at || utc_now()
    update_run(run, attrs, %{status: "waiting_approval", started_at: started_at})
  end

  @spec mark_completed(AgentRun.t(), String.t(), map()) :: {:ok, AgentRun.t()}
  def mark_completed(%AgentRun{} = run, summary, attrs \\ %{}) when is_binary(summary) do
    finished_at = attr(attrs, :finished_at) || utc_now()
    update_run(run, attrs, %{status: "completed", summary: summary, finished_at: finished_at})
  end

  @spec mark_failed(AgentRun.t(), String.t(), map()) :: {:ok, AgentRun.t()}
  def mark_failed(%AgentRun{} = run, error, attrs \\ %{}) when is_binary(error) do
    finished_at = attr(attrs, :finished_at) || utc_now()
    update_run(run, attrs, %{status: "failed", error: error, finished_at: finished_at})
  end

  @spec mark_cancelled(AgentRun.t(), map()) :: {:ok, AgentRun.t()}
  def mark_cancelled(%AgentRun{} = run, attrs \\ %{}) do
    finished_at = attr(attrs, :finished_at) || utc_now()
    update_run(run, attrs, %{status: "cancelled", finished_at: finished_at})
  end

  @spec recover_stale_running_runs(keyword()) :: {non_neg_integer(), nil}
  def recover_stale_running_runs(opts \\ []) do
    older_than = Keyword.get(opts, :older_than, DateTime.add(utc_now(), -3600, :second))

    stale =
      scan()
      |> Enum.filter(fn run ->
        run.status in ["running", "waiting_approval"] and
          DateTime.compare(run.started_at || run.inserted_at, older_than) == :lt
      end)

    Enum.each(stale, fn run ->
      update_run(run, %{}, %{status: "failed", error: @stale_error, finished_at: utc_now()})
    end)

    {length(stale), nil}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp update_run(%AgentRun{} = run, attrs, lifecycle_attrs) do
    merged = run |> Map.merge(normalize_attrs(attrs)) |> Map.merge(lifecycle_attrs)
    updated = %{merged | updated_at: utc_now()}
    persist(updated)
    {:ok, updated}
  end

  defp persist(%AgentRun{} = run) do
    case KV.put(@prefix <> run.id, Map.from_struct(run)) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  defp scan do
    case KV.prefix_scan(@prefix) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, pairs} ->
        Enum.map(pairs, fn {_k, v} -> struct(AgentRun, Concord.Compression.decompress(v)) end)

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
          nil -> acc
          field -> Map.put(acc, field, value)
        end

      _other, acc ->
        acc
    end)
  end

  defp attr(attrs, key), do: Map.get(normalize_attrs(attrs), key)

  defp utc_now, do: DateTime.utc_now()
end
