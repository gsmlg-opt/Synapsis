defmodule Synapsis.Samgita.Inbox do
  @moduledoc """
  Durable inbox of Samgita `project_events.v1` events, keyed by `event_id`.

  Every write returns only after its Concord compare-and-swap commits, so a host
  may report `acceptance: "durable"` for an entry returned from `record/1`.
  The stored `"event"` omits `delivery_attempt_id`: redeliveries of the same
  logical event are duplicates; the same `event_id` with other content conflicts.

  A write's reads, compare-and-swaps and retries share one `@write_budget_ms`
  deadline, below the 5 s Samgita allows a host to answer.

  New entries are also indexed by `received_at` (`@index_prefix`, written in the
  same transaction) so `list/1` reads only the newest `limit` entries. Entries
  stored before the index existed are indexed once, on first list.

  Data only — callers broadcast changes.
  """

  @prefix "coord/samgita/inbox/"
  # `~` is outside the base64url alphabet of entry keys, so these never collide.
  @index_prefix @prefix <> "~at/"
  @indexed_marker @prefix <> "~indexed"
  @timeout 5_000
  @write_budget_ms 4_000
  @cas_attempts 3

  @type entry :: %{String.t() => term()}

  @spec record(map()) :: {:ok, :new | :duplicate, entry} | {:error, :conflict | term}
  def record(%{"event_id" => event_id, "delivery_attempt_id" => attempt_id} = event)
      when is_binary(event_id) and is_binary(attempt_id) do
    logical = Map.delete(event, "delivery_attempt_id")

    cas(event_id, fn
      nil ->
        now = now()

        {:ok, :new,
         %{
           "event" => logical,
           "last_delivery_attempt_id" => attempt_id,
           "acceptance" => "durable",
           "processing_status" => "pending",
           "received_at" => now,
           "updated_at" => now
         }}

      %{"event" => ^logical} = entry ->
        {:ok, :duplicate, %{entry | "last_delivery_attempt_id" => attempt_id}}

      _other ->
        {:error, :conflict}
    end)
  end

  @spec get(String.t()) :: {:ok, entry} | {:error, :not_found | term}
  def get(event_id) do
    case Concord.KV.get(key(event_id), engine: :turso, timeout: @timeout) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @spec list(pos_integer()) :: [entry]
  def list(limit) when is_integer(limit) and limit > 0 do
    ensure_indexed()

    case Concord.Turso.list(
           prefix: @index_prefix,
           order: :desc,
           limit: limit,
           keys_only: true,
           timeout: @timeout
         ) do
      {:ok, records, _page} ->
        Enum.flat_map(records, fn %{key: index_key} ->
          case Concord.KV.get(entry_key_of(index_key), engine: :turso, timeout: @timeout) do
            {:ok, entry} -> [entry]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # One-time index of entries stored before the received_at index existed.
  defp ensure_indexed do
    case Concord.KV.get(@indexed_marker, engine: :turso, timeout: @timeout) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        with {:ok, pairs} <- Concord.Turso.prefix_scan(@prefix, timeout: @timeout) do
          for {key, value} <- pairs, not String.starts_with?(key, @prefix <> "~") do
            # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
            entry = Concord.Compression.decompress(value)
            Concord.Turso.put(index_key(entry["received_at"], key), true, timeout: @timeout)
          end

          Concord.Turso.put(@indexed_marker, true, timeout: @timeout)
        end

      _ ->
        :ok
    end
  end

  @spec mark_processed(String.t(), String.t(), String.t() | nil) ::
          {:ok, entry} | {:error, :not_found | term}
  def mark_processed(event_id, note, decision_id \\ nil) when is_binary(note) do
    fields =
      %{"processing_status" => "completed", "note" => note}
      |> then(
        &if(decision_id,
          do: Map.merge(&1, %{"decision_id" => decision_id, "decision" => %{"note" => note}}),
          else: &1
        )
      )

    cas(event_id, fn
      nil -> {:error, :not_found}
      entry -> {:ok, :updated, Map.merge(entry, fields)}
    end)
    |> unwrap()
  end

  @spec record_report(String.t(), map()) :: {:ok, entry} | {:error, :not_found | :conflict | term}
  def record_report(event_id, %{"decision_id" => decision_id, "status" => status} = report) do
    fields = %{
      "decision_id" => decision_id,
      "processing_status" => status,
      "decision" => Map.get(report, "decision", %{}),
      "result" => Map.get(report, "result")
    }

    cas(event_id, fn
      nil ->
        {:error, :not_found}

      %{"decision_id" => nil} = entry ->
        {:ok, :updated, Map.merge(entry, fields)}

      %{"decision_id" => _} = entry ->
        if Map.take(entry, Map.keys(fields)) == fields,
          do: {:ok, :unchanged, entry},
          else: {:error, :conflict}

      entry ->
        {:ok, :updated, Map.merge(entry, fields)}
    end)
    |> unwrap()
  end

  defp unwrap({:ok, _tag, entry}), do: {:ok, entry}
  defp unwrap(other), do: other

  # Read with storage revision, apply `fun`, and commit with CAS; retries lost
  # races. Every step shares one deadline.
  defp cas(event_id, fun),
    do: cas(event_id, fun, 1, System.monotonic_time(:millisecond) + @write_budget_ms)

  defp cas(event_id, fun, attempt, deadline) do
    key = key(event_id)

    read =
      with {:ok, timeout} <- remaining(deadline) do
        case Concord.KV.get(key, engine: :turso, metadata: true, timeout: timeout) do
          {:ok, %Concord.KV.Record{value: value, mod_revision: rev}} -> {:ok, value, rev}
          {:error, :not_found} -> {:ok, nil, 0}
          {:error, _} = error -> error
        end
      end

    with {:ok, current, rev} <- read,
         {:ok, tag, next} <- fun.(current) do
      if tag == :unchanged or next == current do
        {:ok, tag, current}
      else
        next = if tag == :new, do: next, else: Map.put(next, "updated_at", now())

        case commit(tag, key, next, rev, deadline) do
          {:ok, true} -> {:ok, tag, next}
          {:ok, false} when attempt < @cas_attempts -> cas(event_id, fun, attempt + 1, deadline)
          {:ok, false} -> {:error, :resource_conflict}
          {:error, _} = error -> error
        end
      end
    end
  end

  # A new entry and its received_at index are created together.
  defp commit(:new, key, entry, _rev, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      spec = %{
        compare: [{:exists, key, :==, false}],
        success: [
          {:put, key, entry, %{}},
          {:put, index_key(entry["received_at"], key), true, %{}}
        ],
        failure: []
      }

      case Concord.Turso.txn(spec, timeout: timeout) do
        {:ok, %{succeeded: succeeded}} -> {:ok, succeeded}
        {:error, _} = error -> error
      end
    end
  end

  defp commit(_tag, key, entry, rev, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      case Concord.Turso.compare_and_swap(key, entry, mod_revision: rev, timeout: timeout) do
        {:ok, %{succeeded: succeeded}} -> {:ok, succeeded}
        {:error, _} = error -> error
      end
    end
  end

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> {:ok, ms}
      _ -> {:error, :timeout}
    end
  end

  defp index_key(received_at, entry_key),
    do:
      @index_prefix <> (received_at || "") <> "/" <> String.replace_prefix(entry_key, @prefix, "")

  defp entry_key_of(index_key),
    do: @prefix <> (index_key |> String.split("/") |> List.last())

  defp key(event_id), do: @prefix <> Base.url_encode64(event_id, padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
