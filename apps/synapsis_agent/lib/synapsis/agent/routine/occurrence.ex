defmodule Synapsis.Agent.Routine.Occurrence do
  @moduledoc """
  Concord-backed routine occurrence records (PRD §8.2 / §8.3).

  Key: `coord/routine_occurrences/<routine_id>/<occurrence_key>`

  Status machine: scheduled | claimed | running | completed | failed | skipped | timed_out
  """

  alias Concord.Turso, as: KV
  alias Synapsis.Agent.Routine.Schedule

  @prefix "coord/routine_occurrences/"

  @active_statuses ~w(claimed running)
  @terminal_statuses ~w(completed failed skipped timed_out)

  @type status :: String.t()

  @type t :: %{
          occurrence_key: String.t(),
          routine_id: String.t(),
          scheduled_for: DateTime.t(),
          status: status(),
          run_id: String.t() | nil,
          attempt: pos_integer(),
          claimed_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          outcome: String.t() | nil,
          error: String.t() | nil,
          skip_reason: String.t() | nil
        }

  @spec key(String.t(), String.t()) :: String.t()
  def key(routine_id, occurrence_key)
      when is_binary(routine_id) and is_binary(occurrence_key) do
    # occurrence_key already embeds routine_id; nest under routine for prefix scans
    safe = String.replace(occurrence_key, "/", "_")
    @prefix <> routine_id <> "/" <> safe
  end

  @spec build(String.t(), DateTime.t(), keyword()) :: t()
  def build(routine_id, %DateTime{} = scheduled_for, opts \\ []) do
    occ_key = Schedule.occurrence_key(routine_id, scheduled_for)

    %{
      occurrence_key: occ_key,
      routine_id: routine_id,
      scheduled_for: DateTime.truncate(scheduled_for, :second),
      status: Keyword.get(opts, :status, "scheduled"),
      run_id: Keyword.get(opts, :run_id),
      attempt: Keyword.get(opts, :attempt, 1),
      claimed_at: Keyword.get(opts, :claimed_at),
      started_at: Keyword.get(opts, :started_at),
      finished_at: Keyword.get(opts, :finished_at),
      outcome: Keyword.get(opts, :outcome),
      error: Keyword.get(opts, :error),
      skip_reason: Keyword.get(opts, :skip_reason)
    }
  end

  @spec get(String.t(), String.t()) :: t() | nil
  def get(routine_id, occurrence_key) do
    case KV.get(key(routine_id, occurrence_key)) do
      {:ok, map} when is_map(map) -> from_store(map)
      _ -> nil
    end
  end

  @spec get_by_key(String.t()) :: t() | nil
  def get_by_key(occurrence_key) when is_binary(occurrence_key) do
    case String.split(occurrence_key, ":", parts: 2) do
      [routine_id, _] -> get(routine_id, occurrence_key)
      _ -> nil
    end
  end

  @doc """
  Create occurrence if absent. Idempotent: returns existing on duplicate key.
  """
  @spec create_if_absent(t()) :: {:ok, t()} | {:error, term()}
  def create_if_absent(%{routine_id: rid, occurrence_key: ok} = occ)
      when is_binary(rid) and is_binary(ok) do
    case get(rid, ok) do
      %{} = existing ->
        {:ok, existing}

      nil ->
        persist(occ)
    end
  end

  @doc """
  Claim a scheduled occurrence for execution. Returns `{:error, :already_claimed}`
  if another status owns the key, or `{:error, :overlap}` when caller detects overlap
  before claim (see Scheduler).
  """
  @spec claim(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def claim(routine_id, occurrence_key, opts \\ []) do
    now = Keyword.get(opts, :now, utc_now())

    case get(routine_id, occurrence_key) do
      nil ->
        {:error, :not_found}

      %{status: "scheduled"} = occ ->
        occ
        |> Map.merge(%{status: "claimed", claimed_at: now, attempt: occ.attempt || 1})
        |> persist()

      %{status: status} = occ when status in @active_statuses ->
        {:error, {:already_active, occ}}

      %{status: status} = occ when status in @terminal_statuses ->
        {:error, {:already_terminal, occ}}

      other ->
        {:error, {:invalid_status, other}}
    end
  end

  @spec mark_started(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def mark_started(%{routine_id: rid, occurrence_key: ok} = _occ, run_id, opts \\ [])
      when is_binary(run_id) do
    now = Keyword.get(opts, :now, utc_now())

    case get(rid, ok) do
      %{status: status} = occ when status in ~w(claimed running) ->
        occ
        |> Map.merge(%{status: "running", run_id: run_id, started_at: now})
        |> persist()

      nil ->
        {:error, :not_found}

      other ->
        {:error, {:invalid_status, other}}
    end
  end

  @spec mark_finished(t() | String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def mark_finished(occ_or_key, status, opts \\ [])

  def mark_finished(%{routine_id: rid, occurrence_key: ok}, status, opts)
      when status in @terminal_statuses do
    mark_finished_key(rid, ok, status, opts)
  end

  def mark_finished(occurrence_key, status, opts)
      when is_binary(occurrence_key) and status in @terminal_statuses do
    case String.split(occurrence_key, ":", parts: 2) do
      [rid, _] -> mark_finished_key(rid, occurrence_key, status, opts)
      _ -> {:error, :invalid_key}
    end
  end

  @spec mark_skipped(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def mark_skipped(routine_id, occurrence_key, reason, opts \\ []) do
    now = Keyword.get(opts, :now, utc_now())
    scheduled_for = Keyword.get(opts, :scheduled_for) || now

    base =
      case get(routine_id, occurrence_key) do
        %{} = existing ->
          existing

        nil ->
          occ = build(routine_id, scheduled_for, status: "scheduled")
          %{occ | occurrence_key: occurrence_key}
      end

    base
    |> Map.merge(%{
      status: "skipped",
      finished_at: now,
      outcome: "skipped",
      skip_reason: reason,
      error: nil
    })
    |> persist()
  end

  @spec list_for_routine(String.t()) :: [t()]
  def list_for_routine(routine_id) when is_binary(routine_id) do
    prefix = @prefix <> routine_id <> "/"

    case KV.prefix_scan(prefix) do
      {:ok, pairs} ->
        Enum.map(pairs, fn {_k, v} ->
          from_store(Concord.Compression.decompress(v))
        end)

      _ ->
        []
    end
  end

  @spec list_active(String.t()) :: [t()]
  def list_active(routine_id) do
    routine_id
    |> list_for_routine()
    |> Enum.filter(&(&1.status in @active_statuses))
  end

  @spec active?(String.t()) :: boolean()
  def active?(routine_id), do: list_active(routine_id) != []

  @spec persist(t()) :: {:ok, t()} | {:error, term()}
  def persist(%{routine_id: rid, occurrence_key: ok} = occ)
      when is_binary(rid) and is_binary(ok) do
    case maybe_inject_put_failure() do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case KV.put(key(rid, ok), to_store(occ)) do
          :ok -> {:ok, occ}
          {:ok, _} -> {:ok, occ}
          other -> {:error, other}
        end
    end
  end

  @spec from_store(map()) :: t()
  def from_store(map) when is_map(map) do
    a = atomize(map)

    %{
      occurrence_key: Map.fetch!(a, :occurrence_key),
      routine_id: Map.fetch!(a, :routine_id),
      scheduled_for: parse_dt(Map.get(a, :scheduled_for)) || utc_now(),
      status: Map.get(a, :status) || "scheduled",
      run_id: Map.get(a, :run_id),
      attempt: Map.get(a, :attempt) || 1,
      claimed_at: parse_dt(Map.get(a, :claimed_at)),
      started_at: parse_dt(Map.get(a, :started_at)),
      finished_at: parse_dt(Map.get(a, :finished_at)),
      outcome: Map.get(a, :outcome),
      error: Map.get(a, :error),
      skip_reason: Map.get(a, :skip_reason)
    }
  end

  @spec to_store(t()) :: map()
  def to_store(occ) do
    %{
      "occurrence_key" => occ.occurrence_key,
      "routine_id" => occ.routine_id,
      "scheduled_for" => dt_iso(occ.scheduled_for),
      "status" => occ.status,
      "run_id" => occ.run_id,
      "attempt" => occ.attempt,
      "claimed_at" => dt_iso(occ.claimed_at),
      "started_at" => dt_iso(occ.started_at),
      "finished_at" => dt_iso(occ.finished_at),
      "outcome" => occ.outcome,
      "error" => occ.error,
      "skip_reason" => occ.skip_reason
    }
  end

  defp mark_finished_key(rid, ok, status, opts) do
    now = Keyword.get(opts, :now, utc_now())

    case get(rid, ok) do
      nil ->
        {:error, :not_found}

      occ ->
        occ
        |> Map.merge(%{
          status: status,
          finished_at: now,
          outcome: Keyword.get(opts, :outcome, status),
          error: Keyword.get(opts, :error),
          run_id: Keyword.get(opts, :run_id, occ.run_id)
        })
        |> persist()
    end
  end

  defp atomize(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_atom(k), v)
    end)
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp dt_iso(nil), do: nil
  defp dt_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_inject_put_failure do
    case Process.get(:synapsis_routine_occurrence_put_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
