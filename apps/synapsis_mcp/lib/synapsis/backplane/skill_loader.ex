defmodule Synapsis.Backplane.SkillLoader do
  @moduledoc "Loads one exact Backplane Skill revision through Skill Protocol v1."

  alias Backplane.SkillProtocol.{Client, Source.Backplane, TemporaryStorage}
  alias Synapsis.Backplane.Connection
  alias Synapsis.SkillCatalog.Entry

  @timeout_ms 10_000
  @max_json_bytes 4 * 1_024 * 1_024
  @max_artifact_bytes 16 * 1_024 * 1_024

  @spec load(Entry.t(), map()) :: {:ok, binary()} | {:error, term()}
  def load(
        %Entry{
          authority: :backplane,
          source_id: source_id,
          skill_id: skill_id,
          revision: revision
        } = entry,
        context
      )
      when is_binary(source_id) and is_binary(skill_id) and is_binary(revision) and revision != "" do
    with {:ok, connection} <- Connection.get(source_id),
         true <- connection.enabled,
         {:ok, client} <- client(connection, context),
         {:ok, parent} <- TemporaryStorage.directory(System.tmp_dir!(), "synapsis-skill"),
         {:ok, content} <- prepare_and_read(client, entry, parent, context) do
      {:ok, content}
    else
      false -> {:error, "Backplane Skill source is disabled"}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def load(%Entry{authority: :backplane}, _context),
    do: {:error, "Backplane Skill locator is not pinned to an exact revision"}

  def load(_entry, _context), do: {:error, "Invalid Backplane Skill source"}

  defp client(connection, context) do
    Client.new(
      endpoint: connection.endpoint,
      source_id: connection.id,
      access_context_id: to_string(context[:session_id] || context[:agent_id] || "synapsis"),
      credential_supplier: fn -> connection.credential end,
      cancelled?: cancellation(context),
      overall_timeout_ms: @timeout_ms,
      max_json_bytes: @max_json_bytes,
      max_artifact_bytes: @max_artifact_bytes,
      max_attempts: 2
    )
  end

  defp prepare_and_read(client, entry, parent, context) do
    destination = Path.join(parent, "prepared")
    source = Backplane.new!(client)

    try do
      with {:ok, prepared} <-
             Backplane.prepare(source, entry.skill_id, entry.revision,
               destination: destination,
               cancelled?: cancellation(context)
             ),
           :ok <- verify_snapshot_digest(entry, prepared),
           true <- is_binary(prepared.document.raw) do
        {:ok, prepared.document.raw}
      else
        false -> {:error, "Prepared Skill document is invalid"}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm_rf(parent)
    end
  end

  defp verify_snapshot_digest(%Entry{artifact_digest: nil}, _prepared), do: :ok

  defp verify_snapshot_digest(%Entry{artifact_digest: digest}, prepared) do
    if prepared.manifest.ref.artifact_digest == digest,
      do: :ok,
      else: {:error, "Backplane Skill artifact changed after session boot"}
  end

  defp cancellation(context) do
    case context[:cancelled?] do
      fun when is_function(fun, 0) -> fun
      _ -> fn -> false end
    end
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
