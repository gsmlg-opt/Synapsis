defmodule Synapsis.Samgita.Inbox do
  @moduledoc """
  Durable inbox of Samgita `project_events.v1` events, keyed by `event_id`.

  Every write returns only after its Concord compare-and-swap commits, so a host
  may report `acceptance: "durable"` for an entry returned from `record/1`.
  The stored `"event"` omits `delivery_attempt_id`: redeliveries of the same
  logical event are duplicates; the same `event_id` with other content conflicts.

  Data only — callers broadcast changes.
  """

  @prefix "coord/samgita/inbox/"
  @timeout 5_000
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
    case Concord.Turso.prefix_scan(@prefix, timeout: @timeout) do
      {:ok, pairs} ->
        # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
        pairs
        |> Enum.map(fn {_key, value} -> Concord.Compression.decompress(value) end)
        |> Enum.sort_by(& &1["received_at"], :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  @spec mark_processed(String.t(), String.t()) :: {:ok, entry} | {:error, :not_found | term}
  def mark_processed(event_id, note) when is_binary(note) do
    cas(event_id, fn
      nil -> {:error, :not_found}
      entry -> {:ok, :updated, Map.merge(entry, %{"processing_status" => "completed", "note" => note})}
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

  # Read with storage revision, apply `fun`, and commit with CAS; retries lost races.
  defp cas(event_id, fun, attempt \\ 1) do
    key = key(event_id)

    read =
      case Concord.KV.get(key, engine: :turso, metadata: true, timeout: @timeout) do
        {:ok, %Concord.KV.Record{value: value, mod_revision: rev}} -> {:ok, value, rev}
        {:error, :not_found} -> {:ok, nil, 0}
        {:error, _} = error -> error
      end

    with {:ok, current, rev} <- read,
         {:ok, tag, next} <- fun.(current) do
      if tag == :unchanged or next == current do
        {:ok, tag, current}
      else
        next = if tag == :new, do: next, else: Map.put(next, "updated_at", now())

        case Concord.Turso.compare_and_swap(key, next, mod_revision: rev, timeout: @timeout) do
          {:ok, %{succeeded: true}} -> {:ok, tag, next}
          {:ok, %{succeeded: false}} when attempt < @cas_attempts -> cas(event_id, fun, attempt + 1)
          {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp key(event_id), do: @prefix <> Base.url_encode64(event_id, padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
