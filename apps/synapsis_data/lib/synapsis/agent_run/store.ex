defmodule Synapsis.AgentRun.Store do
  @moduledoc """
  Atomic storage of node-local run projections and serialized critical facts.

  The agent layer owns validation and reduction. This module fences expected
  snapshots and commits their projection, event and indexes in one transaction.
  """

  alias Synapsis.AgentRun

  @runs "coord/agent_runs/"
  @events "coord/agent_run_events/"
  @event_ids "coord/agent_run_event_ids/"
  @idempotency "coord/agent_run_idempotency/"
  @timeout 5_000

  def fetch(id) do
    with {:ok, raw} <- read(@runs <> id), do: {:ok, AgentRun.from_store(raw)}
  end

  def fetch_by_idempotency(key) do
    with {:ok, index} <- read(@idempotency <> key) do
      case Map.get(index, "run_id") || Map.get(index, :run_id) do
        id when is_binary(id) ->
          case fetch(id) do
            :not_found -> {:error, :incomplete_idempotency}
            result -> result
          end

        _ ->
          {:error, :incomplete_idempotency}
      end
    end
  end

  def list do
    with {:ok, pairs} <- scan(@runs) do
      {:ok, Enum.map(pairs, fn {_key, value} -> AgentRun.from_store(value) end)}
    end
  end

  def list_events(run_id) do
    with {:ok, pairs} <- scan(@events <> run_id <> "/") do
      {:ok, pairs |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1["sequence"])}
    end
  end

  def event_index(id), do: read(@event_ids <> id)

  # Legacy indexes have no commit revision. They cannot prove that their
  # independently written projection committed, so require reconciliation.
  def fetch_event(id) do
    with {:ok, index} <- event_index(id) do
      case index do
        %{"run_id" => run_id, "sequence" => seq, "type" => type, "revision" => revision}
        when is_integer(revision) and revision > 0 ->
          with {:ok, body} <- read(event_key(run_id, seq, id)),
               {:ok, run} <- fetch(run_id) do
            if body["event_id"] == id and body["run_id"] == run_id and
                 body["sequence"] == seq and body["type"] == type and
                 run.revision >= revision and run.last_event_sequence >= seq do
              {:ok, body, run}
            else
              {:error, :incomplete_event}
            end
          else
            :not_found -> {:error, :incomplete_event}
            {:error, _} = error -> error
          end

        _ ->
          {:error, :incomplete_event}
      end
    end
  end

  def create(%AgentRun{} = run, body) do
    {compares, puts} = event_operations(run, body)
    {index_compares, index_puts} = idempotency_operations(run)

    spec = %{
      compare: [{:exists, @runs <> run.id, :==, false}] ++ compares ++ index_compares,
      success: [{:put, @runs <> run.id, AgentRun.to_store_map(run), %{}}] ++ puts ++ index_puts,
      failure: []
    }

    case adapter().txn(spec, timeout: @timeout) do
      {:ok, %{succeeded: true}} -> {:ok, run, :committed}
      {:ok, %{succeeded: false}} -> existing_creation(run)
      {:error, _} = error -> reconcile(body, error)
    end
  end

  def commit(%AgentRun{} = expected, %AgentRun{} = proposed, body) do
    case committed(body) do
      :not_found -> commit_new(expected, proposed, body)
      result -> result
    end
  end

  # Compatibility entry point: a raw snapshot can acknowledge identical durable
  # state, but cannot create or change lifecycle state without a critical fact.
  def persist(%AgentRun{} = run) do
    case fetch(run.id) do
      {:ok, ^run} -> {:ok, run}
      {:error, _} = error -> error
      _ -> {:error, :lifecycle_event_required}
    end
  end

  defp commit_new(expected, proposed, body) do
    with {:ok, raw} <- read(@runs <> expected.id),
         true <- AgentRun.from_store(raw) == expected,
         :ok <- check_history(expected),
         :not_found <- read(event_key(body)) do
      {compares, puts} = event_operations(proposed, body)

      spec = %{
        compare: [{:value, @runs <> expected.id, :==, raw} | compares],
        success: [{:put, @runs <> expected.id, AgentRun.to_store_map(proposed), %{}} | puts],
        failure: []
      }

      case adapter().txn(spec, timeout: @timeout) do
        {:ok, %{succeeded: true}} -> {:ok, proposed, :committed}
        {:ok, %{succeeded: false}} -> reconcile(body, {:error, :stale_run})
        {:error, _} = error -> reconcile(body, error)
      end
    else
      false -> reconcile(body, {:error, :stale_run})
      :not_found -> {:error, :not_found}
      {:ok, _existing_event} -> reconcile(body, {:error, :incomplete_event})
      {:error, _} = error -> reconcile(body, error)
    end
  end

  # Before this boundary became atomic, a crash could leave a future event
  # without advancing the projection. A fresh event ID must not bypass that
  # unresolved fact. New writers are fenced by the snapshot comparison below.
  defp check_history(expected) do
    with {:ok, events} <- list_events(expected.id) do
      if Enum.any?(events, &(&1["sequence"] > expected.last_event_sequence)) do
        case fetch(expected.id) do
          {:ok, ^expected} -> {:error, :incomplete_event}
          {:ok, _newer} -> {:error, :stale_run}
          :not_found -> {:error, :not_found}
          {:error, _} = error -> error
        end
      else
        :ok
      end
    end
  end

  defp committed(body) do
    case fetch_event(body["event_id"]) do
      {:ok, ^body, run} -> {:ok, run, :duplicate}
      {:ok, _other, _run} -> {:error, :event_id_conflict}
      result -> result
    end
  end

  defp reconcile(body, error) do
    case committed(body) do
      :not_found -> error
      result -> result
    end
  end

  defp existing_creation(%AgentRun{idempotency_key: key}) when is_binary(key) and key != "" do
    case fetch_by_idempotency(key) do
      {:ok, run} -> {:ok, run, :duplicate}
      :not_found -> {:error, :already_exists}
      {:error, _} = error -> error
    end
  end

  defp existing_creation(_), do: {:error, :already_exists}

  defp event_operations(run, body) do
    event_key = event_key(body)
    id_key = @event_ids <> body["event_id"]
    index = Map.take(body, ~w(run_id sequence type)) |> Map.put("revision", run.revision)

    {[
       {:exists, event_key, :==, false},
       {:exists, id_key, :==, false}
     ], [{:put, event_key, body, %{}}, {:put, id_key, index, %{}}]}
  end

  defp idempotency_operations(%AgentRun{idempotency_key: key, id: id})
       when is_binary(key) and key != "" do
    key = @idempotency <> key
    {[{:exists, key, :==, false}], [{:put, key, %{"run_id" => id}, %{}}]}
  end

  defp idempotency_operations(_), do: {[], []}

  defp event_key(body), do: event_key(body["run_id"], body["sequence"], body["event_id"])

  defp event_key(run_id, sequence, id) do
    @events <>
      run_id <> "/" <> String.pad_leading(Integer.to_string(sequence), 12, "0") <> "-" <> id
  end

  defp read(key) do
    case adapter().get(key, timeout: @timeout) do
      {:error, :not_found} -> :not_found
      {:ok, value} -> {:ok, Concord.Compression.decompress(value)}
      result -> result
    end
  end

  defp scan(prefix) do
    with {:ok, pairs} <- adapter().prefix_scan(prefix, timeout: @timeout) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, Enum.map(pairs, fn {key, value} -> {key, Concord.Compression.decompress(value)} end)}
    end
  end

  defp adapter, do: Application.get_env(:synapsis_data, :agent_run_store_adapter, Concord.Turso)
end
