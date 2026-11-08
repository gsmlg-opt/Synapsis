defmodule Synapsis.Runtime.Store do
  @moduledoc """
  Concord storage for opaque runtime aggregates and subagent journal facts.

  The agent layer owns transitions. This module acknowledges atomic writes only
  after Concord commits. The aggregate's revision and incarnation are checked
  against one metadata read, then its storage revision is compared atomically.
  No runtime effects are executed here.

  A valid aggregate commit shares one requested five-second budget between its
  metadata read and CAS, recalculating the remaining timeout before each call.
  This cannot forcibly interrupt native work or prove no late write. A known
  successful CAS acknowledgement remains successful, even after that budget.
  Other store operations retain their own per-call timeouts.
  """

  @prefix "coord/runtime/"
  @timeout 5_000

  defmodule ConcordAdapter do
    @moduledoc false

    def get(key, opts), do: Concord.KV.get(key, Keyword.put(opts, :engine, :turso))
    defdelegate compare_and_swap(key, value, opts), to: Concord.Turso
    defdelegate txn(spec, opts), to: Concord.Turso
    defdelegate prefix_scan(prefix, opts), to: Concord.Turso
  end

  def load(namespace, run_id), do: read(run_key(namespace, run_id))

  def commit(namespace, run_id, expected_revision, expected_incarnation, aggregate)
      when is_integer(expected_revision) and expected_revision >= 0 and
             is_integer(expected_incarnation) and expected_incarnation >= 0 and
             is_map(aggregate) do
    if aggregate[:revision] == expected_revision + 1 and
         is_integer(aggregate[:incarnation]) and
         aggregate[:incarnation] >= expected_incarnation do
      deadline = System.monotonic_time(:millisecond) + @timeout
      key = run_key(namespace, run_id)

      with {:ok, timeout} <- remaining_timeout(deadline) do
        case adapter().get(key, metadata: true, timeout: timeout) do
          {:error, :not_found} when expected_revision == 0 ->
            compare_and_swap(key, aggregate, 0, deadline)

          {:ok,
           %Concord.KV.Record{
             value: %{revision: ^expected_revision, incarnation: ^expected_incarnation},
             mod_revision: mod_revision
           }} ->
            compare_and_swap(key, aggregate, mod_revision, deadline)

          {:error, :not_found} ->
            {:error, :resource_conflict}

          {:error, _} = error ->
            error

          _ ->
            {:error, :resource_conflict}
        end
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

  def get_fact(session_id, kind, identity),
    do: read(fact_prefix(session_id, kind) <> segment(identity))

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

  defp compare_and_swap(key, value, mod_revision, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      case adapter().compare_and_swap(key, value, mod_revision: mod_revision, timeout: timeout) do
        {:ok, %{succeeded: true}} -> :ok
        {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
        {:error, _} = error -> error
      end
    end
  end

  defp remaining_timeout(deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end

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
  defp adapter, do: Application.get_env(:synapsis_data, :runtime_store_adapter, ConcordAdapter)
end
