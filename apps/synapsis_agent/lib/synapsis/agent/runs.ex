defmodule Synapsis.Agent.Runs do
  @moduledoc "Lifecycle API for persisted daemon run records."

  import Ecto.Query

  alias Synapsis.{AgentRun, Repo}

  @stale_error "daemon restarted before completion"
  @updatable_fields ~w(
    kind status source assistant_name session_id heartbeat_id routine_id prompt
    tool_profile model provider summary error started_at finished_at metadata
  )a

  @spec create(map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %AgentRun{}
    |> AgentRun.changeset(normalize_attrs(attrs))
    |> Repo.insert()
  end

  @spec get(String.t()) :: AgentRun.t() | nil
  def get(id), do: Repo.get(AgentRun, id)

  @spec list_recent(keyword()) :: [AgentRun.t()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AgentRun
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_by_status(String.t(), keyword()) :: [AgentRun.t()]
  def list_by_status(status, opts \\ []) when is_binary(status) do
    limit = Keyword.get(opts, :limit, 50)

    AgentRun
    |> where([run], run.status == ^status)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec mark_running(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(%AgentRun{} = run, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    started_at = attr(attrs, :started_at) || run.started_at || utc_now()

    update_run(run, attrs, %{status: "running", started_at: started_at})
  end

  @spec mark_waiting_approval(AgentRun.t(), map()) ::
          {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_waiting_approval(%AgentRun{} = run, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    started_at = attr(attrs, :started_at) || run.started_at || utc_now()

    update_run(run, attrs, %{status: "waiting_approval", started_at: started_at})
  end

  @spec mark_completed(AgentRun.t(), String.t(), map()) ::
          {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%AgentRun{} = run, summary, attrs \\ %{}) when is_binary(summary) do
    attrs = normalize_attrs(attrs)
    finished_at = attr(attrs, :finished_at) || utc_now()

    update_run(run, attrs, %{status: "completed", summary: summary, finished_at: finished_at})
  end

  @spec mark_failed(AgentRun.t(), String.t(), map()) ::
          {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%AgentRun{} = run, error, attrs \\ %{}) when is_binary(error) do
    attrs = normalize_attrs(attrs)
    finished_at = attr(attrs, :finished_at) || utc_now()

    update_run(run, attrs, %{status: "failed", error: error, finished_at: finished_at})
  end

  @spec mark_cancelled(AgentRun.t(), map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_cancelled(%AgentRun{} = run, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    finished_at = attr(attrs, :finished_at) || utc_now()

    update_run(run, attrs, %{status: "cancelled", finished_at: finished_at})
  end

  @spec recover_stale_running_runs(keyword()) :: {non_neg_integer(), nil | [term()]}
  def recover_stale_running_runs(opts \\ []) do
    older_than = Keyword.get(opts, :older_than, DateTime.add(utc_now(), -3600, :second))
    now = utc_now()

    AgentRun
    |> where([run], run.status in ["running", "waiting_approval"])
    |> where(
      [run],
      (not is_nil(run.started_at) and run.started_at < ^older_than) or
        (is_nil(run.started_at) and run.inserted_at < ^older_than)
    )
    |> Repo.update_all(
      set: [
        status: "failed",
        error: @stale_error,
        finished_at: now,
        updated_at: now
      ]
    )
  end

  defp update_run(%AgentRun{} = run, attrs, lifecycle_attrs) do
    attrs = Map.merge(attrs, lifecycle_attrs)

    run
    |> AgentRun.changeset(attrs)
    |> Repo.update()
  end

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

  defp attr(attrs, key), do: Map.get(attrs, key)

  defp utc_now, do: DateTime.utc_now()
end
