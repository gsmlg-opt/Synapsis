defmodule Synapsis.Samgita.Coordination do
  @moduledoc """
  Durable project-event coordination journal. Plans and exact command identities
  precede effects; receipts survive process replacement. No credentials are stored.
  """
  @prefix "coord/samgita/coordination/"
  @timeout 4_000

  def enqueue(device_id, %{"project_ref" => project, "event_id" => event_id} = event)
      when is_binary(device_id) and is_binary(project) and is_binary(event_id) do
    id =
      Enum.map_join([device_id, project, event_id], "/", &Base.url_encode64(&1, padding: false))

    entry = %{
      "id" => id,
      "device_id" => device_id,
      "project_id" => project,
      "event_id" => event_id,
      "event" => Map.delete(event, "delivery_attempt_id"),
      "phase" => "queued",
      "commands" => %{},
      "children" => %{},
      "updated_at" => now()
    }

    case Concord.Turso.txn(
           %{
             compare: [{:exists, key(id), :==, false}],
             success: [{:put, key(id), entry, %{}}],
             failure: []
           },
           timeout: @timeout
         ) do
      {:ok, %{succeeded: true}} -> {:ok, :new, entry}
      {:ok, %{succeeded: false}} -> with {:ok, entry} <- get(id), do: {:ok, :existing, entry}
      error -> error
    end
  end

  def enqueue(_, _), do: {:error, :invalid_event}
  def get(id), do: Concord.KV.get(key(id), engine: :turso, timeout: @timeout)

  def list(device_id \\ nil) do
    prefix =
      if device_id,
        do: @prefix <> Base.url_encode64(device_id, padding: false) <> "/",
        else: @prefix

    pages(prefix, [prefix: prefix], [])
  end

  # Descending pages continue below the previous last key. Prepending each
  # record preserves the ascending key order returned to callers.
  defp pages(prefix, selection, acc) do
    opts = selection ++ [order: :desc, limit: 100, timeout: @timeout, queue: true]

    case Concord.Turso.list(opts) do
      {:ok, records, page} ->
        entries = Enum.reduce(records, acc, fn record, entries -> [record.value | entries] end)

        if page.has_more,
          do: pages(prefix, [range: {prefix, page.last_key}], entries),
          else: entries

      {:error, _} = error ->
        error
    end
  end

  def update(id, fun, attempts \\ 3) do
    with {:ok, %Concord.KV.Record{value: current, mod_revision: revision}} <-
           Concord.KV.get(key(id), engine: :turso, metadata: true, timeout: @timeout),
         {:ok, next} <- fun.(current) do
      next = Map.put(next, "updated_at", now())

      case Concord.Turso.compare_and_swap(key(id), next,
             mod_revision: revision,
             timeout: @timeout
           ) do
        {:ok, %{succeeded: true}} -> {:ok, next}
        {:ok, %{succeeded: false}} when attempts > 1 -> update(id, fun, attempts - 1)
        {:ok, %{succeeded: false}} -> {:error, :conflict}
        error -> error
      end
    end
  end

  def owned(id, token, fun) do
    update(id, fn entry ->
      if entry["owner_token"] == token, do: fun.(entry), else: {:error, :ownership_lost}
    end)
  end

  def public(entry), do: Map.drop(entry, ["owner_token"])
  defp key(id), do: @prefix <> id
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
