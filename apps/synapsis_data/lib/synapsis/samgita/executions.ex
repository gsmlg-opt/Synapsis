defmodule Synapsis.Samgita.Executions do
  @moduledoc """
  Durable per-device Task execution journal. Reservations precede every external
  effect. Only `queued` records may start automatically; all later interrupted
  phases require observation/reconciliation and never authorize another run.
  """
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary
  @prefix "coord/samgita/executions/"
  @timeout 4_000
  @terminal ~w(completed failed ignored)

  def enqueue(device_id, %{"task_ref" => task_id, "project_ref" => project_id} = event)
      when is_binary(device_id) and is_binary(task_id) and is_binary(project_id) do
    id = device_id <> "/" <> project_id <> "/" <> task_id

    entry = %{
      "id" => id,
      "device_id" => device_id,
      "project_id" => project_id,
      "task_id" => task_id,
      "event_id" => event["event_id"],
      "phase" => "queued",
      "updated_at" => now(),
      "commands" => Map.new(~w(session claim start progress report), &{&1, Ecto.UUID.generate()})
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
    prefix = if device_id, do: @prefix <> encoded(device_id) <> "/", else: @prefix

    case Concord.Turso.list(prefix: prefix, limit: 1_000, timeout: @timeout, queue: true) do
      {:ok, _records, %{has_more: true}} ->
        {:error, :journal_truncated}

      {:ok, records, %{has_more: false}} ->
        Enum.reduce_while(records, [], fn record, entries ->
          case get(String.replace_prefix(record.key, @prefix, "") |> decode_id()) do
            {:ok, entry} -> {:cont, [entry | entries]}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  def active?(device_id) do
    case list(device_id) do
      entries when is_list(entries) -> Enum.any?(entries, &(&1["phase"] not in @terminal))
      {:error, _} -> true
    end
  end

  def start(id, owner_token \\ Ecto.UUID.generate()),
    do: write(id, "checking_assignment", %{"owner_token" => owner_token}, "queued")

  def update(id, phase, fields \\ %{}), do: write(id, phase, fields, :any)
  def update_owned(id, token, phase, fields \\ %{}), do: write(id, phase, fields, {:owner, token})

  def revoke(id, reason, attempts \\ 3) do
    with {:ok, current} <- get(id) do
      result =
        if current["phase"] in @terminal,
          do: {:ok, current},
          else:
            update(id, "recovery_required", %{
              "owner_token" => nil,
              "last_error" =>
                if(current["phase"] == "recovery_required",
                  do: current["last_error"] || reason,
                  else: reason
                )
            })

      case result do
        {:error, :conflict} when attempts > 1 -> revoke(id, reason, attempts - 1)
        other -> other
      end
    end
  end

  defp write(id, phase, fields, expected) do
    with {:ok, %Concord.KV.Record{value: current, mod_revision: revision}} <-
           Concord.KV.get(key(id), engine: :turso, metadata: true, timeout: @timeout),
         true <- owns?(current, expected) do
      entry =
        current |> Map.merge(fields) |> Map.put("phase", phase) |> Map.put("updated_at", now())

      case Concord.Turso.compare_and_swap(key(id), entry,
             mod_revision: revision,
             timeout: @timeout
           ) do
        {:ok, %{succeeded: true}} -> {:ok, entry}
        {:ok, %{succeeded: false}} -> {:error, :conflict}
        error -> error
      end
    else
      false -> {:error, :already_started}
      error -> error
    end
  end

  defp owns?(_current, :any), do: true
  defp owns?(current, {:owner, token}), do: is_binary(token) and current["owner_token"] == token
  defp owns?(current, phase), do: current["phase"] == phase

  def save_proof(id, proof, owner_token) when is_binary(proof) do
    with {:ok, encrypted} <- EncryptedBinary.dump(proof),
         {:ok, entry} <- get(id),
         {:ok, _} <-
           update_owned(id, owner_token, entry["phase"], %{
             "proof_encrypted" => Base.encode64(encrypted)
           }) do
      :ok
    end
  end

  def public(entry), do: Map.drop(entry, ["proof_encrypted", "owner_token"])
  defp key(id), do: @prefix <> (id |> String.split("/") |> Enum.map_join("/", &encoded/1))
  defp encoded(id), do: Base.url_encode64(id, padding: false)

  defp decode_id(id),
    do: id |> String.split("/") |> Enum.map_join("/", &Base.url_decode64!(&1, padding: false))

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
