defmodule Synapsis.Diffs.ArtifactStore do
  @moduledoc """
  Acknowledged Concord registrations for expiring Diffs artifacts.

  Logical revisions fence lifecycle transitions. A namespace ledger and public
  index are committed with each registration/removal, using Concord MVCC fences.
  Cleanup claims retain their original root and descriptor until removal is
  acknowledged. No filesystem work or automatic TTL deletion happens here.
  Deadlines are absolute monotonic milliseconds and bound all composed calls.
  """

  @records "diffs/artifacts/"
  @indexes "diffs/public/"
  @roots "diffs/roots/"
  @ledger "diffs/namespace"
  @entry_limit 2048
  @viewer_limit 32 * 1024 * 1024
  @namespace_limit 256 * 1024 * 1024

  def reserve(attrs, deadline) when is_map(attrs) and is_integer(deadline) do
    with :ok <- validate_attrs(attrs),
         :ok <- active(deadline) do
      now = System.system_time(:millisecond)

      record =
        Map.merge(Map.delete(attrs, :descriptor), %{
          version: 1,
          id: Ecto.UUID.generate(),
          public_id: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower),
          revision: 1,
          state: :reserved,
          created_at: now,
          expires_at: now + attrs.ttl_ms
        })

      reserve_record(record, deadline, 8)
    end
  end

  def reserve(_, _), do: {:error, :invalid_artifact}

  def complete(id, revision, descriptor, deadline) do
    transition(id, revision, deadline, fn record ->
      with true <- record.state == :reserved,
           true <- record.expires_at > System.system_time(:millisecond),
           :ok <- validate_descriptor(record, descriptor) do
        {:ok,
         %{record | state: :complete, revision: record.revision + 1}
         |> Map.put(:descriptor, descriptor)}
      else
        false -> {:error, :artifact_unavailable}
        error -> error
      end
    end)
  end

  def lookup(public_id, now, deadline) do
    with true <- public_id?(public_id) and is_integer(now),
         {:ok, id, _} <- read(@indexes <> public_id, deadline),
         {:ok, record, _} <- read(@records <> id, deadline),
         true <-
           record.public_id == public_id and record.state == :complete and record.expires_at > now do
      {:ok, record}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def retire(id, revision, deadline) do
    transition(id, revision, deadline, fn record ->
      if record.state in [:reserved, :complete] do
        {:ok, %{record | state: :cleanup_pending, revision: record.revision + 1}}
      else
        {:error, :resource_conflict}
      end
    end)
  end

  def claim_expired(now, deadline) when is_integer(now) do
    with {:ok, records} <- live_records(deadline) do
      records
      |> Enum.filter(&(&1.state in [:reserved, :complete] and &1.expires_at <= now))
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, claimed} ->
        case retire(record.id, record.revision, deadline) do
          {:ok, receipt} -> {:cont, {:ok, [receipt | claimed]}}
          {:error, :resource_conflict} -> {:cont, {:ok, claimed}}
          {:error, :not_found} -> {:cont, {:ok, claimed}}
          error -> {:halt, error}
        end
      end)
      |> reverse_records()
    end
  end

  def pending_cleanup(deadline) do
    with {:ok, records} <- live_records(deadline),
         do: {:ok, Enum.filter(records, &(&1.state == :cleanup_pending))}
  end

  @doc "All registered records, including pending cleanup, for orphan exclusion."
  def live_records(deadline), do: scan(@records, deadline)

  @doc "Original roots remain registered after removal and config replacement."
  def roots(deadline), do: scan(@roots, deadline)

  def ack_removed(id, revision, deadline), do: remove_record(id, revision, deadline, 8)

  defp reserve_record(_record, _deadline, 0), do: {:error, :resource_conflict}

  defp reserve_record(record, deadline, attempts) do
    with {:ok, ledger, fence} <- ledger(deadline),
         true <- ledger.entries < @entry_limit,
         :ok <- active(deadline) do
      key = @records <> record.id
      index = @indexes <> record.public_id
      root_key = @roots <> Base.encode16(:crypto.hash(:sha256, record.root), case: :lower)
      compare = [fence, {:exists, key, :==, false}, {:exists, index, :==, false}]

      operations = [
        put(key, record),
        put(index, record.id),
        put(root_key, record.root),
        put(@ledger, %{ledger | entries: ledger.entries + 1})
      ]

      case transact(compare, operations, deadline) do
        :ok -> {:ok, record}
        {:error, :resource_conflict} -> reserve_record(record, deadline, attempts - 1)
        error -> error
      end
    else
      false -> {:error, :artifact_quota}
      error -> error
    end
  end

  defp transition(id, revision, deadline, change),
    do: transition(id, revision, deadline, change, 8)

  defp transition(_id, _revision, _deadline, _change, 0), do: {:error, :resource_conflict}

  defp transition(id, revision, deadline, change, attempts) do
    with :ok <- uuid(id),
         {:ok, record, mod_revision} <- read(@records <> id, deadline),
         true <- record.revision == revision,
         {:ok, changed} <- change.(record),
         {:ok, ledger, ledger_fence} <- ledger(deadline),
         bytes = ledger.viewer_bytes + stored_bytes(changed) - stored_bytes(record),
         :ok <- namespace_capacity(bytes),
         :ok <- completion_live(changed) do
      operations = [put(@records <> id, changed), put(@ledger, %{ledger | viewer_bytes: bytes})]

      case transact(
             [{:mod_revision, @records <> id, :==, mod_revision}, ledger_fence],
             operations,
             deadline
           ) do
        :ok -> {:ok, changed}
        {:error, :resource_conflict} -> transition(id, revision, deadline, change, attempts - 1)
        error -> error
      end
    else
      false -> {:error, :resource_conflict}
      error -> error
    end
  end

  defp remove_record(_id, _revision, _deadline, 0), do: {:error, :resource_conflict}

  defp remove_record(id, revision, deadline, attempts) do
    with :ok <- uuid(id),
         {:ok, record, mod_revision} <- read(@records <> id, deadline),
         true <- record.state == :cleanup_pending and record.revision == revision,
         {:ok, ledger, ledger_fence} <- ledger(deadline) do
      operations = [
        {:delete, {:key, @records <> id}, %{}},
        {:delete, {:key, @indexes <> record.public_id}, %{}},
        put(@ledger, %{
          ledger
          | entries: ledger.entries - 1,
            viewer_bytes: ledger.viewer_bytes - stored_bytes(record)
        })
      ]

      case transact(
             [{:mod_revision, @records <> id, :==, mod_revision}, ledger_fence],
             operations,
             deadline
           ) do
        :ok -> :ok
        {:error, :resource_conflict} -> remove_record(id, revision, deadline, attempts - 1)
        error -> error
      end
    else
      false -> {:error, :resource_conflict}
      error -> error
    end
  end

  defp validate_attrs(attrs) do
    valid =
      attrs[:kind] in [:viewer, :file] and absolute_root?(attrs[:root]) and
        is_integer(attrs[:max_bytes]) and attrs.max_bytes > 0 and attrs.max_bytes <= @viewer_limit and
        is_integer(attrs[:ttl_ms]) and attrs.ttl_ms in 1000..21_600_000 and
        is_map(attrs[:context]) and is_map(attrs[:metadata]) and
        (attrs.kind != :viewer or hash?(attrs[:token_hash]))

    with true <- valid,
         :ok <- uuid(attrs[:session_id]),
         :ok <- uuid(attrs[:agent_id]),
         :ok <- invocation(attrs[:invocation]),
         {:ok, _} <- Jason.encode(attrs.context),
         {:ok, _} <- Jason.encode(attrs.metadata) do
      :ok
    else
      _ -> {:error, :invalid_artifact}
    end
  end

  defp validate_descriptor(record, descriptor) when is_map(descriptor) do
    format = descriptor["format"]
    viewer? = record.kind == :viewer

    name =
      if viewer?,
        do: "viewer.html.gz",
        else: Map.get(%{"png" => "preview.png", "pdf" => "preview.pdf"}, format)

    mime =
      if viewer?,
        do: "text/html; charset=utf-8",
        else: Map.get(%{"png" => "image/png", "pdf" => "application/pdf"}, format)

    bytes = descriptor["bytes"]

    valid =
      descriptor["version"] == 1 and descriptor["artifactId"] == record.public_id and
        descriptor["kind"] == Atom.to_string(record.kind) and is_binary(name) and
        descriptor["path"] == Path.join(record.public_id, name) and
        descriptor["mimeType"] == mime and not is_nil(mime) and hash?(descriptor["sha256"]) and
        is_integer(bytes) and bytes > 0 and bytes <= record.max_bytes and
        if(viewer?,
          do:
            format == "html" and descriptor["encoding"] == "gzip" and
              is_integer(descriptor["decodedBytes"]) and descriptor["decodedBytes"] > 0 and
              descriptor["decodedBytes"] <= record.max_bytes and bytes <= @viewer_limit,
          else: format in ~w(png pdf) and format == record.metadata["format"]
        )

    with true <- valid,
         {:ok, _} <- Jason.encode(descriptor),
         do: :ok,
         else: (_ -> {:error, :invalid_descriptor})
  end

  defp validate_descriptor(_, _), do: {:error, :invalid_descriptor}

  defp stored_bytes(%{kind: :viewer, descriptor: descriptor}), do: descriptor["bytes"]
  defp stored_bytes(_), do: 0

  defp namespace_capacity(bytes),
    do: if(bytes <= @namespace_limit, do: :ok, else: {:error, :artifact_quota})

  defp completion_live(%{state: :complete, expires_at: expires_at}) do
    if expires_at > System.system_time(:millisecond),
      do: :ok,
      else: {:error, :artifact_unavailable}
  end

  defp completion_live(_), do: :ok

  defp ledger(deadline) do
    case read(@ledger, deadline) do
      {:ok, ledger, revision} ->
        {:ok, ledger, {:mod_revision, @ledger, :==, revision}}

      {:error, :not_found} ->
        {:ok, %{entries: 0, viewer_bytes: 0}, {:exists, @ledger, :==, false}}

      error ->
        error
    end
  end

  defp read(key, deadline) do
    with {:ok, timeout} <- timeout(deadline) do
      case Concord.KV.get(key, engine: :turso, metadata: true, timeout: timeout) do
        {:ok, %Concord.KV.Record{value: value, mod_revision: revision}} -> {:ok, value, revision}
        error -> error
      end
    end
  end

  defp scan(prefix, deadline) do
    with {:ok, timeout} <- timeout(deadline),
         {:ok, pairs} <- Concord.Turso.prefix_scan(prefix, timeout: timeout),
         :ok <- active(deadline) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      values = Enum.map(pairs, fn {_key, value} -> Concord.Compression.decompress(value) end)
      with :ok <- active(deadline), do: {:ok, values}
    end
  end

  defp transact(compare, operations, deadline) do
    with {:ok, timeout} <- timeout(deadline) do
      case Concord.Turso.txn(%{compare: compare, success: operations, failure: []},
             timeout: timeout
           ) do
        {:ok, %{succeeded: true}} -> :ok
        {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
        error -> error
      end
    end
  end

  defp put(key, value), do: {:put, key, value, %{}}

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> :ok
      _ -> {:error, :invalid_artifact}
    end
  end

  defp invocation(id) when is_binary(id) and byte_size(id) in 1..4096 do
    if String.valid?(id) and not String.contains?(id, <<0>>),
      do: :ok,
      else: {:error, :invalid_artifact}
  end

  defp invocation(_), do: {:error, :invalid_artifact}

  defp public_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-f0-9]{20}\z/, id)
  defp hash?(hash), do: is_binary(hash) and Regex.match?(~r/\A[a-f0-9]{64}\z/, hash)

  defp absolute_root?(root),
    do:
      is_binary(root) and String.valid?(root) and not String.contains?(root, <<0>>) and
        Path.type(root) == :absolute and
        Path.expand(root) == root

  defp reverse_records({:ok, records}), do: {:ok, Enum.reverse(records)}
  defp reverse_records(error), do: error

  defp active(deadline) do
    case timeout(deadline) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp timeout(deadline) when is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, min(remaining, 5000)}, else: {:error, :timeout}
  end

  defp timeout(_), do: {:error, :invalid_deadline}
end
