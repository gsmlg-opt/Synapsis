defmodule Synapsis.Agent.DiffsDelivery do
  @moduledoc """
  Expiring public Diffs delivery composed from data registrations and Workspace IO.

  Each publication pins its original root, bound, expiry and native provenance.
  Immutable file facts survive cleanup but never restore availability: every
  read also checks the live ArtifactStore registration. Publication, completion,
  fact acknowledgement and native settlement are separate operations. Uncertain
  effects are never retried. Only a known quota rejection permits one cleanup
  sweep followed by another reservation attempt, without repeating rendering.
  """

  alias Synapsis.Agent.DiffsCleanup
  alias Synapsis.Diffs.ArtifactStore
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.DiffArtifacts

  @max_bytes 32 * 1024 * 1024
  @invocation_keys [:run_id, :invocation_id, :tool_call_id, :tool_name]

  def publish_viewer(rendered, plan, binding, opts) do
    with {:ok, settings} <- settings(opts),
         {:ok, provenance} <- provenance(binding),
         {:ok, html_receipt, metadata} <- viewer_rendered(rendered),
         {:ok, %{bytes: html}} <-
           DiffArtifacts.read_staged(html_receipt, io_opts(settings, opts)),
         token = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower),
         {:ok, attrs} <- attrs(:viewer, plan, binding, provenance, metadata, settings),
         attrs = Map.put(attrs, :token_hash, hash(token)),
         {:ok, record} <- reserve(attrs, settings.deadline),
         {:ok, descriptor} <-
           DiffArtifacts.put_viewer(record.root, record.public_id, html, io_opts(settings, opts)),
         {:ok, completed} <-
           complete(record, descriptor, settings.deadline) do
      {:ok,
       %{
         record: completed,
         descriptor: descriptor,
         token: token,
         viewer_path: "/plugins/diffs/view/#{completed.public_id}/#{token}",
         expires_at: iso8601(completed.expires_at)
       }}
    end
  end

  def reserve_file(plan, binding, opts) do
    with {:ok, settings} <- settings(opts),
         {:ok, provenance} <- provenance(binding),
         format when format in ~w(png pdf) <- get_in(plan, ["options", "image", "format"]),
         {:ok, attrs} <- attrs(:file, plan, binding, provenance, %{"format" => format}, settings) do
      reserve(attrs, settings.deadline)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_delivery}
    end
  end

  def complete_file(reservation, staged_receipt, opts) do
    with {:ok, settings} <- settings(opts, reservation),
         true <- valid_reservation?(reservation),
         :ok <- current_reservation(reservation, settings.deadline),
         format = reservation.metadata["format"],
         {:ok, descriptor} <-
           DiffArtifacts.put_file(
             reservation.root,
             reservation.public_id,
             format,
             staged_receipt,
             io_opts(settings, opts)
           ),
         {:ok, completed} <-
           complete(reservation, descriptor, settings.deadline),
         delivery_id = completed.delivery_id,
         reference = %{"version" => 1, "session_id" => completed.session_id, "id" => delivery_id},
         fact = %{
           version: 1,
           session_id: completed.session_id,
           agent_id: completed.agent_id,
           artifact_id: completed.id,
           public_id: completed.public_id,
           root: completed.root,
           max_bytes: completed.max_bytes,
           expires_at: completed.expires_at,
           descriptor: descriptor,
           invocation: completed.invocation_provenance
         },
         :ok <-
           fact_call(
             fn ->
               Store.put_fact(completed.session_id, :diffs_file_delivery, delivery_id, fact)
             end,
             settings.deadline,
             :write
           ) do
      {:ok,
       %{
         record: completed,
         descriptor: descriptor,
         reference: reference,
         file_path: DiffArtifacts.file_path(completed.root, completed.public_id, format),
         expires_at: iso8601(completed.expires_at)
       }}
    else
      false -> {:error, :invalid_delivery}
      error -> error
    end
  end

  def read_viewer(public_id, token, opts) do
    with {:ok, deadline} <- deadline(opts),
         true <- is_binary(token) and Regex.match?(~r/\A[a-f0-9]{48}\z/, token),
         {:ok, record} <-
           ArtifactStore.lookup(public_id, System.system_time(:millisecond), deadline),
         true <- record.kind == :viewer and secure_hash?(hash(token), record.token_hash),
         {:ok, bytes} <-
           DiffArtifacts.read(record.descriptor,
             root: record.root,
             max_bytes: record.max_bytes,
             deadline: deadline
           ) do
      {:ok, Map.put(bytes, :record, record)}
    else
      false -> {:error, :delivery_not_found}
      error -> error
    end
  end

  def read_file(session_id, delivery_id, opts) do
    with {:ok, deadline} <- deadline(opts),
         true <- uuid?(session_id) and uuid?(delivery_id),
         {:ok, fact} <-
           fact_call(
             fn -> Store.get_fact(session_id, :diffs_file_delivery, delivery_id) end,
             deadline
           ),
         {:ok, record} <- live_fact(session_id, fact, deadline),
         true <- record.delivery_id == delivery_id,
         {:ok, bytes} <-
           DiffArtifacts.read(record.descriptor,
             root: record.root,
             max_bytes: record.max_bytes,
             deadline: deadline
           ) do
      {:ok, Map.put(bytes, :record, record)}
    else
      false -> {:error, :invalid_delivery}
      :not_found -> {:error, :delivery_not_found}
      error -> error
    end
  end

  def resolve_attachment(session_id, path, opts) do
    with {:ok, deadline} <- deadline(opts),
         true <- uuid?(session_id) and canonical_path?(path),
         {:ok, records} <- ArtifactStore.live_records(deadline),
         record when is_map(record) <-
           Enum.find(records, &attachment_record?(&1, session_id, path)),
         {:ok, bytes} <- read_file(session_id, record.delivery_id, deadline: deadline) do
      {:ok, Map.put(bytes, :file_path, path)}
    else
      false -> {:error, :invalid_attachment}
      nil -> {:error, :delivery_not_found}
      error -> error
    end
  end

  def viewer_url(%{viewer_path: path}, urls) when is_binary(path) and is_map(urls) do
    base =
      Enum.find([urls[:base_url], urls[:viewer_base_url], urls[:host_origin]], fn value ->
        is_binary(value) and String.trim(value) != ""
      end)

    with true <- is_binary(base),
         {:ok, resolved} <- Synapsis.Diffs.Config.resolve(%{"viewerBaseUrl" => base}),
         normalized when is_binary(normalized) <- resolved["viewerBaseUrl"],
         true <- Regex.match?(~r/\A\/plugins\/diffs\/view\/[a-f0-9]{20}\/[a-f0-9]{48}\z/, path) do
      uri = URI.parse(normalized)
      {:ok, URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/") <> path})}
    else
      _ -> {:error, :invalid_viewer_url}
    end
  end

  def viewer_url(_, _), do: {:error, :invalid_viewer_url}

  def file_url(%{"version" => 1, "session_id" => session_id, "id" => id} = reference)
      when map_size(reference) == 3 do
    if uuid?(session_id) and uuid?(id),
      do: {:ok, "/api/diffs/files/#{session_id}/#{id}"},
      else: {:error, :invalid_delivery}
  end

  def file_url(_), do: {:error, :invalid_delivery}

  def remove_artifact(record, opts) when is_map(record) do
    with {:ok, deadline} <- deadline(opts),
         {:ok, pending} <- cleanup_claim(record, deadline),
         :ok <-
           DiffArtifacts.remove(pending.root, pending.public_id,
             max_bytes: pending.max_bytes,
             deadline: deadline
           ),
         :ok <- ArtifactStore.ack_removed(pending.id, pending.revision, deadline) do
      :ok
    end
  end

  defp cleanup_claim(%{state: :cleanup_pending, id: id, revision: revision}, deadline) do
    with {:ok, pending} <- ArtifactStore.pending_cleanup(deadline) do
      case Enum.find(pending, &(&1.id == id and &1.revision == revision)) do
        nil -> {:error, :resource_conflict}
        record -> {:ok, record}
      end
    end
  end

  defp cleanup_claim(%{id: id, revision: revision}, deadline),
    do: ArtifactStore.retire(id, revision, deadline)

  defp cleanup_claim(_, _), do: {:error, :invalid_delivery}

  defp complete(record, descriptor, deadline) do
    case ArtifactStore.complete(record.id, record.revision, descriptor, deadline) do
      {:error, :artifact_quota} ->
        with {:ok, _} <- DiffsCleanup.sweep(deadline),
             do: ArtifactStore.complete(record.id, record.revision, descriptor, deadline)

      result ->
        result
    end
  end

  defp reserve(attrs, deadline) do
    result =
      case ArtifactStore.reserve(attrs, deadline) do
        {:error, :artifact_quota} ->
          with {:ok, _} <- DiffsCleanup.sweep(deadline),
               do: ArtifactStore.reserve(attrs, deadline)

        other ->
          other
      end

    case result do
      {:ok, _} ->
        DiffsCleanup.allocated()
        result

      error ->
        error
    end
  end

  defp attrs(kind, plan, binding, provenance, metadata, settings) when is_map(plan) do
    ttl = plan["ttlMs"]
    context = Map.get(plan, "context", %{})

    if is_integer(ttl) and ttl in 1000..21_600_000 and is_map(context) do
      attributes = %{
        kind: kind,
        root: settings.root,
        max_bytes: settings.max_bytes,
        session_id: binding.session_id,
        agent_id: binding.agent_id,
        invocation: provenance.invocation_id,
        invocation_provenance: provenance,
        context: context,
        metadata: metadata,
        ttl_ms: ttl
      }

      {:ok,
       if(kind == :file,
         do: Map.put(attributes, :delivery_id, Ecto.UUID.generate()),
         else: attributes
       )}
    else
      {:error, :invalid_delivery}
    end
  end

  defp attrs(_, _, _, _, _, _), do: {:error, :invalid_delivery}

  defp viewer_rendered(%{
         "title" => title,
         "inputKind" => input_kind,
         "fileCount" => count,
         "artifacts" => %{"html" => receipt}
       })
       when is_binary(title) and input_kind in ~w(before_after patch) and is_integer(count) and
              count > 0 and is_map(receipt) do
    {:ok, receipt, %{"title" => title, "inputKind" => input_kind, "fileCount" => count}}
  end

  defp viewer_rendered(_), do: {:error, :invalid_rendered_viewer}

  defp provenance(%{session_id: session_id, agent_id: agent_id, invocation: invocation})
       when is_map(invocation) do
    selected = Map.take(invocation, @invocation_keys)

    if uuid?(session_id) and uuid?(agent_id) and
         Enum.all?([:run_id, :invocation_id, :tool_call_id], &identifier?(selected[&1])) and
         selected[:tool_name] == "synapsis::diffs" do
      {:ok, selected}
    else
      {:error, :invalid_invocation}
    end
  end

  defp provenance(_), do: {:error, :invalid_invocation}

  defp valid_reservation?(record) when is_map(record) do
    record[:state] == :reserved and record[:kind] == :file and
      is_map(record[:metadata]) and record.metadata["format"] in ~w(png pdf) and
      uuid?(record[:delivery_id]) and
      match?(
        {:ok, _},
        provenance(%{
          session_id: record[:session_id],
          agent_id: record[:agent_id],
          invocation: record[:invocation_provenance]
        })
      )
  end

  defp valid_reservation?(_), do: false

  defp current_reservation(reservation, deadline) do
    with {:ok, records} <- ArtifactStore.live_records(deadline),
         true <-
           Enum.any?(
             records,
             &(&1 === reservation and &1.expires_at > System.system_time(:millisecond))
           ) do
      :ok
    else
      false -> {:error, :artifact_unavailable}
      error -> error
    end
  end

  defp live_fact(
         session_id,
         %{
           version: 1,
           session_id: session_id,
           agent_id: agent_id,
           artifact_id: id,
           public_id: public_id,
           root: root,
           max_bytes: max_bytes,
           expires_at: expires_at,
           descriptor: descriptor,
           invocation: invocation
         },
         deadline
       ) do
    with {:ok, ^invocation} <-
           provenance(%{session_id: session_id, agent_id: agent_id, invocation: invocation}),
         {:ok, record} <-
           ArtifactStore.lookup(public_id, System.system_time(:millisecond), deadline),
         true <-
           record.kind == :file and record.id == id and record.session_id == session_id and
             record.agent_id == agent_id and
             record.root == root and record.max_bytes == max_bytes and
             record.expires_at == expires_at and
             record.descriptor == descriptor and record.invocation_provenance == invocation and
             record.invocation == invocation.invocation_id do
      {:ok, record}
    else
      false -> {:error, :delivery_unavailable}
      error -> error
    end
  end

  defp live_fact(_, _, _), do: {:error, :delivery_unavailable}

  defp attachment_record?(
         %{
           kind: :file,
           state: :complete,
           session_id: session_id,
           root: root,
           public_id: id,
           delivery_id: delivery_id,
           descriptor: %{"format" => format}
         },
         session_id,
         path
       )
       when is_binary(root) and is_binary(id) and format in ~w(png pdf) do
    uuid?(delivery_id) and DiffArtifacts.file_path(root, id, format) == path
  end

  defp attachment_record?(_, _, _), do: false

  defp settings(opts, record \\ nil) do
    with {:ok, deadline} <- deadline(opts) do
      root = if is_map(record), do: record[:root], else: Keyword.get(opts, :root)

      max_bytes =
        if is_map(record), do: record[:max_bytes], else: Keyword.get(opts, :max_bytes, @max_bytes)

      if canonical_path?(root) and is_integer(max_bytes) and max_bytes in 1..@max_bytes,
        do: {:ok, %{root: root, max_bytes: max_bytes, deadline: deadline}},
        else: {:error, :invalid_options}
    end
  end

  defp deadline(opts) when is_list(opts) do
    value = Keyword.get(opts, :deadline, now() + 30_000)
    if is_integer(value) and value > now(), do: {:ok, value}, else: {:error, :timeout}
  end

  defp deadline(_), do: {:error, :invalid_options}

  defp io_opts(settings, opts),
    do: [
      max_bytes: settings.max_bytes,
      deadline: settings.deadline,
      staging_root: Keyword.get(opts, :staging_root)
    ]

  # Runtime.Store owns facts and has a five-second internal timeout. The caller
  # owns this bounded supervised task; an uncertain write is never retried.
  defp fact_call(callback, deadline, kind \\ :read) do
    remaining = deadline - now()

    if remaining > 0 do
      task = Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, callback)

      case Task.yield(task, remaining) do
        {:ok, result} ->
          cond do
            now() >= deadline -> fact_uncertain(kind, :timeout)
            result == {:error, :timeout} -> fact_uncertain(kind, :timeout)
            true -> result
          end

        {:exit, _} ->
          fact_uncertain(kind, :delivery_unavailable)

        nil ->
          Task.shutdown(task, :brutal_kill)
          fact_uncertain(kind, :timeout)
      end
    else
      {:error, :timeout}
    end
  catch
    :exit, _ -> fact_uncertain(kind, :delivery_unavailable)
  end

  defp fact_uncertain(:write, _reason), do: {:error, :delivery_uncertain}
  defp fact_uncertain(:read, reason), do: {:error, reason}

  defp canonical_path?(path),
    do:
      is_binary(path) and String.valid?(path) and not String.contains?(path, <<0>>) and
        Path.type(path) == :absolute and Path.expand(path) == path

  defp uuid?(id), do: is_binary(id) and Ecto.UUID.cast(id) == {:ok, id}

  defp identifier?(id),
    do:
      is_binary(id) and byte_size(id) in 1..4096 and String.valid?(id) and
        not String.contains?(id, <<0>>)

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp iso8601(milliseconds),
    do: milliseconds |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp secure_hash?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_hash?(_, _), do: false
  defp now, do: System.monotonic_time(:millisecond)
end
