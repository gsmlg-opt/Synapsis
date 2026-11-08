defmodule Synapsis.Agent.Runtime.SessionUsage do
  @moduledoc """
  Read-only projection of committed, retained Backplane run usage.

  Backplane owns accounting. This adapter reads its version-pinned ledger and
  accepted attempt inventory; it never sums raw cumulative usage events. A
  metric is available only when every retained address was read and every
  accepted attempt has a matching native report and a known cumulative value.
  Cached and reasoning counts are breakdowns, not additional billable tokens.

  Observations are sequential across retained runs, not a session-wide storage
  snapshot or a claim about imported/unretained history. In-flight provider
  attempts can leave metrics unknown. No pricing or accounting state is stored.
  Reads run outside the Worker mailbox under one capped five-second deadline.
  The 32 MiB inventory bound applies after decoding existing Store values.
  """

  alias Backplane.AgentRuntime.Usage
  alias Synapsis.Runtime.Store, as: Journal

  @version "1.10.60"
  @metrics ~w(input_tokens cached_tokens output_tokens reasoning_tokens)a
  @inventory_limit 32 * 1_024 * 1_024

  def read(session_id, deadline) do
    with true <- is_binary(session_id) and match?({:ok, ^session_id}, Ecto.UUID.cast(session_id)),
         true <- is_integer(deadline),
         true <- to_string(Application.spec(:backplane_agent_runtime, :vsn)) == @version,
         deadline = min(deadline, now() + 5_000),
         :ok <- remaining(deadline) do
      task = Task.async(fn -> load(session_id, deadline) end)

      case Task.yield(task, max(0, deadline - now())) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    else
      false -> {:error, :usage_unavailable}
      error -> error
    end
  end

  defp load(session_id, deadline) do
    with {:ok, locators} <- Journal.list_facts(session_id, :run_locator),
         true <- :erlang.external_size(locators) <= @inventory_limit,
         :ok <- remaining(deadline),
         {:ok, addresses} <- retained_addresses(locators, session_id),
         {:ok, rows} <- load_runs(addresses, deadline),
         {:ok, projected} <- project_runs(rows),
         :ok <- remaining(deadline) do
      {:ok, projected}
    else
      false -> {:error, :payload_too_large}
      {:error, _} = error -> error
      _ -> {:error, :malformed_metadata}
    end
  rescue
    _ -> {:error, :usage_unavailable}
  catch
    :exit, _ -> {:error, :usage_unavailable}
  end

  # Incarnation locators address the same current aggregate. Deduplicate before
  # storage reads, so each retained address has exactly one sequential observation.
  defp retained_addresses(locators, session_id) when is_list(locators) do
    Enum.reduce_while(locators, {:ok, MapSet.new()}, fn locator, {:ok, addresses} ->
      case locator do
        %{session_id: ^session_id, namespace: namespace, run_id: run_id}
        when is_binary(namespace) and namespace != "" and is_binary(run_id) and run_id != "" ->
          {:cont, {:ok, MapSet.put(addresses, {namespace, run_id})}}

        _ ->
          {:halt, {:error, :malformed_metadata}}
      end
    end)
  end

  defp retained_addresses(_, _), do: {:error, :malformed_metadata}

  defp load_runs(addresses, deadline) do
    addresses
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}, 0}, fn {namespace, run_id} = address, {:ok, rows, bytes} ->
      with :ok <- remaining(deadline),
           {:ok, entry} <- load_run(namespace, run_id),
           true <- bytes + :erlang.external_size(entry) <= @inventory_limit do
        {:cont, {:ok, Map.put(rows, address, entry), bytes + :erlang.external_size(entry)}}
      else
        false -> {:halt, {:error, :payload_too_large}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _bytes} -> {:ok, rows}
      error -> error
    end
  end

  defp load_run(namespace, run_id) do
    case Journal.load(namespace, run_id) do
      {:ok, aggregate} ->
        if valid_aggregate?(aggregate, :present, run_id),
          do: {:ok, %{aggregate: aggregate, availability: :present}},
          else: {:error, :malformed_metadata}

      :not_found ->
        {:ok, %{aggregate: nil, availability: :absent}}

      error ->
        error
    end
  end

  defp valid_aggregate?(%{revision: revision, incarnation: incarnation, run: run}, :present, id),
    do:
      is_integer(revision) and revision > 0 and is_integer(incarnation) and incarnation > 0 and
        is_map(run) and run[:run_id] == id and run[:incarnation] == incarnation and
        run[:expected_revision] == revision

  defp valid_aggregate?(_, _, _), do: false

  defp project_runs(rows) do
    present = rows |> Map.values() |> Enum.filter(&(&1.availability == :present))

    Enum.reduce_while(present, {:ok, []}, fn entry, {:ok, runs} ->
      case project_run(entry.aggregate.run) do
        {:ok, run} -> {:cont, {:ok, [run | runs]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, runs} ->
        all_present = map_size(rows) == length(present)

        metrics =
          Map.new(@metrics, fn key ->
            values = Enum.map(runs, & &1.metrics[key])
            known = all_present and Enum.all?(values, &(is_integer(&1) and &1 >= 0))
            {key, if(known, do: Enum.sum(values))}
          end)

        {:ok,
         %{
           source: "native_committed",
           coverage: "retained_runs",
           observation: "sequential",
           runtime_version: @version,
           retained_runs: map_size(rows),
           observed_runs: length(present),
           provider_attempts: Enum.sum(Enum.map(runs, & &1.attempts)),
           metrics: metrics,
           cost: %{status: "unavailable"}
         }}

      error ->
        error
    end
  end

  defp project_run(run) do
    attempts = Map.get(run, :provider_attempts, %{})
    conversation = get_in(run, [:context, :conversation]) || %{}
    ledger = Map.get(conversation, :goal_usage)
    snapshots = Map.get(conversation, :goal_stream_usage, %{})

    with true <- is_map(attempts) and is_map(conversation) and is_map(snapshots),
         true <- Enum.all?(attempts, &valid_attempt?(&1, run)),
         {:ok, totals, reports} <- native_totals(ledger),
         true <- Enum.all?(@metrics, &(is_integer(totals[&1]) and totals[&1] >= 0)) do
      metrics =
        Map.new(@metrics, fn metric ->
          values =
            Enum.map(attempts, fn {id, identity} ->
              report = "#{identity.run_id}:#{identity.incarnation}:#{id}"
              snapshot = Map.get(snapshots, id, %{})

              if Map.has_key?(reports, report) and is_map(snapshot),
                do: Map.get(snapshot, metric)
            end)

          known = Enum.all?(values, &(is_integer(&1) and &1 >= 0))

          # The native ledger remains the value authority. Its cumulative
          # snapshots only qualify completeness and corroborate that value.
          value = if known and Enum.sum(values) == totals[metric], do: totals[metric]
          {metric, value}
        end)

      {:ok, %{attempts: map_size(attempts), metrics: metrics}}
    else
      _ -> {:error, :malformed_metadata}
    end
  end

  defp valid_attempt?({id, identity}, run) when is_binary(id) and is_map(identity),
    do:
      identity[:attempt_id] == id and identity[:run_id] == run.run_id and
        is_integer(identity[:incarnation]) and identity.incarnation > 0 and
        identity.incarnation <= run.incarnation and is_binary(identity[:step_id])

  defp valid_attempt?(_, _), do: false

  defp native_totals(nil), do: {:ok, Map.new(@metrics, &{&1, 0}), %{}}

  defp native_totals(%{totals: totals, reports: reports} = ledger)
       when is_map(totals) and is_map(reports),
       do: {:ok, Usage.totals(ledger), reports}

  defp native_totals(_), do: {:error, :malformed_metadata}

  defp remaining(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
