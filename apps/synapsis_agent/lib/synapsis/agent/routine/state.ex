defmodule Synapsis.Agent.Routine.State do
  @moduledoc """
  Concord-backed mutable routine scheduler state (PRD §8.2).

  Key: `coord/routines/<routine_id>/state`
  """

  alias Concord.Turso, as: KV

  @prefix "coord/routines/"

  @type t :: %{
          routine_id: String.t(),
          last_evaluated_at: DateTime.t() | nil,
          last_scheduled_at: DateTime.t() | nil,
          last_started_at: DateTime.t() | nil,
          last_completed_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_run_id: String.t() | nil,
          failure_streak: non_neg_integer(),
          backoff_until: DateTime.t() | nil,
          last_error: String.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec key(String.t()) :: String.t()
  def key(routine_id) when is_binary(routine_id), do: @prefix <> routine_id <> "/state"

  @spec get(String.t()) :: t() | nil
  def get(routine_id) when is_binary(routine_id) do
    case KV.get(key(routine_id)) do
      {:ok, map} when is_map(map) -> from_store(map)
      _ -> nil
    end
  end

  @spec get_or_new(String.t()) :: t()
  def get_or_new(routine_id) when is_binary(routine_id) do
    get(routine_id) || new(routine_id)
  end

  @spec new(String.t()) :: t()
  def new(routine_id) when is_binary(routine_id) do
    %{
      routine_id: routine_id,
      last_evaluated_at: nil,
      last_scheduled_at: nil,
      last_started_at: nil,
      last_completed_at: nil,
      next_run_at: nil,
      last_run_id: nil,
      failure_streak: 0,
      backoff_until: nil,
      last_error: nil,
      updated_at: nil
    }
  end

  @spec persist(t()) :: {:ok, t()} | {:error, term()}
  def persist(%{routine_id: routine_id} = state) when is_binary(routine_id) do
    now = utc_now()
    state = Map.put(state, :updated_at, now)

    case maybe_inject_put_failure() do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case KV.put(key(routine_id), to_store(state)) do
          :ok -> {:ok, state}
          {:ok, _} -> {:ok, state}
          other -> {:error, other}
        end
    end
  end

  @spec put_next_run(String.t(), DateTime.t() | nil) :: {:ok, t()} | {:error, term()}
  def put_next_run(routine_id, next_run_at) do
    state =
      routine_id
      |> get_or_new()
      |> Map.put(:next_run_at, next_run_at)
      |> Map.put(:last_scheduled_at, utc_now())
      |> Map.put(:last_evaluated_at, utc_now())

    persist(state)
  end

  @spec record_success(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def record_success(routine_id, run_id) do
    state =
      routine_id
      |> get_or_new()
      |> Map.merge(%{
        failure_streak: 0,
        backoff_until: nil,
        last_error: nil,
        last_run_id: run_id,
        last_completed_at: utc_now()
      })

    persist(state)
  end

  @spec record_failure(String.t(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def record_failure(routine_id, error, opts \\ []) do
    retry = Keyword.get(opts, :retry_policy, %{})
    run_id = Keyword.get(opts, :run_id)
    now = Keyword.get(opts, :now, utc_now())

    state = get_or_new(routine_id)
    streak = state.failure_streak + 1
    max_attempts = Map.get(retry, :max_attempts) || Map.get(retry, "max_attempts") || 3
    base_ms = Map.get(retry, :base_ms) || Map.get(retry, "base_ms") || 60_000
    max_ms = Map.get(retry, :max_ms) || Map.get(retry, "max_ms") || 3_600_000

    backoff_until =
      if streak < max_attempts do
        delay = min(trunc(base_ms * :math.pow(2, streak - 1)), max_ms)
        DateTime.add(now, delay, :millisecond)
      else
        # Exhausted attempts — still set a max backoff window before next schedule claim.
        DateTime.add(now, max_ms, :millisecond)
      end

    state
    |> Map.merge(%{
      failure_streak: streak,
      backoff_until: backoff_until,
      last_error: error && to_string(error),
      last_run_id: run_id || state.last_run_id,
      last_completed_at: now
    })
    |> persist()
  end

  @spec in_backoff?(t(), DateTime.t()) :: boolean()
  def in_backoff?(%{backoff_until: %DateTime{} = until}, %DateTime{} = now) do
    DateTime.compare(now, until) == :lt
  end

  def in_backoff?(_, _), do: false

  @spec from_store(map()) :: t()
  def from_store(map) when is_map(map) do
    atomized = atomize(map)

    %{
      routine_id: Map.fetch!(atomized, :routine_id),
      last_evaluated_at: parse_dt(Map.get(atomized, :last_evaluated_at)),
      last_scheduled_at: parse_dt(Map.get(atomized, :last_scheduled_at)),
      last_started_at: parse_dt(Map.get(atomized, :last_started_at)),
      last_completed_at: parse_dt(Map.get(atomized, :last_completed_at)),
      next_run_at: parse_dt(Map.get(atomized, :next_run_at)),
      last_run_id: Map.get(atomized, :last_run_id),
      failure_streak: Map.get(atomized, :failure_streak) || 0,
      backoff_until: parse_dt(Map.get(atomized, :backoff_until)),
      last_error: Map.get(atomized, :last_error),
      updated_at: parse_dt(Map.get(atomized, :updated_at))
    }
  end

  @spec to_store(t()) :: map()
  def to_store(state) do
    %{
      "routine_id" => state.routine_id,
      "last_evaluated_at" => dt_iso(state.last_evaluated_at),
      "last_scheduled_at" => dt_iso(state.last_scheduled_at),
      "last_started_at" => dt_iso(state.last_started_at),
      "last_completed_at" => dt_iso(state.last_completed_at),
      "next_run_at" => dt_iso(state.next_run_at),
      "last_run_id" => state.last_run_id,
      "failure_streak" => state.failure_streak,
      "backoff_until" => dt_iso(state.backoff_until),
      "last_error" => state.last_error,
      "updated_at" => dt_iso(state.updated_at)
    }
  end

  defp atomize(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_existing_atom(k), v)
    end)
  rescue
    ArgumentError ->
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
    case Process.get(:synapsis_routine_state_put_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
