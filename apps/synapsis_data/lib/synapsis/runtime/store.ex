defmodule Synapsis.Runtime.Store do
  @moduledoc """
  Concord storage for opaque runtime aggregates and subagent journal facts.

  The agent layer owns transitions. This module acknowledges atomic writes only
  after Concord commits, comparing the aggregate's revision and incarnation in
  the same transaction. No runtime effects are executed here.
  """

  @prefix "coord/runtime/"
  @timeout 5_000

  def load(namespace, run_id), do: read(run_key(namespace, run_id))

  def commit(namespace, run_id, expected_revision, expected_incarnation, aggregate)
      when is_integer(expected_revision) and expected_revision >= 0 and
             is_integer(expected_incarnation) and expected_incarnation >= 0 and
             is_map(aggregate) do
    if aggregate[:revision] == expected_revision + 1 and
         is_integer(aggregate[:incarnation]) and
         aggregate[:incarnation] >= expected_incarnation do
      key = run_key(namespace, run_id)

      case read(key) do
        :not_found when expected_revision == 0 ->
          transact([{:exists, key, :==, false}], key, aggregate)

        {:ok, %{revision: ^expected_revision, incarnation: ^expected_incarnation} = current} ->
          transact([{:value, key, :==, current}], key, aggregate)

        {:error, _} = error ->
          error

        _ ->
          {:error, :resource_conflict}
      end
    else
      {:error, :invalid_aggregate}
    end
  end

  def put_fact(session_id, kind, identity, value) do
    key = fact_prefix(session_id, kind) <> segment(identity)

    case transact([{:exists, key, :==, false}], key, value) do
      {:error, :resource_conflict} ->
        case read(key) do
          {:ok, ^value} -> :ok
          {:ok, _} -> {:error, :fact_conflict}
          other -> other
        end

      result ->
        result
    end
  end

  def list_facts(session_id, kind) do
    with {:ok, pairs} <- adapter().prefix_scan(fact_prefix(session_id, kind), timeout: @timeout) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, Enum.map(pairs, fn {_key, value} -> Concord.Compression.decompress(value) end)}
    end
  end

  def put_projection(session_id, value) do
    transact([], projection_key(session_id), value)
  end

  def get_projection(session_id), do: read(projection_key(session_id))

  defp transact(compare, key, value) do
    spec = %{compare: compare, success: [{:put, key, value, %{}}], failure: []}

    case adapter().txn(spec, timeout: @timeout) do
      {:ok, %{succeeded: true}} -> :ok
      {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
      {:error, _} = error -> error
    end
  end

  defp read(key) do
    case adapter().get(key, timeout: @timeout) do
      {:ok, value} -> {:ok, Concord.Compression.decompress(value)}
      {:error, :not_found} -> :not_found
      result -> result
    end
  end

  defp run_key(namespace, run_id),
    do: @prefix <> "runs/" <> segment(namespace) <> "/" <> segment(run_id)

  defp fact_prefix(session_id, kind),
    do: @prefix <> "facts/" <> segment(session_id) <> "/" <> segment(kind) <> "/"

  defp projection_key(session_id), do: @prefix <> "projections/" <> segment(session_id)
  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp adapter, do: Application.get_env(:synapsis_data, :runtime_store_adapter, Concord.Turso)
end
