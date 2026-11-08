defmodule Synapsis.Workflow.Continuations do
  @moduledoc """
  Durable, versioned workflow snapshots owned by a session and agent.

  Snapshots are opaque string-keyed JSON maps. Callers own their meaning,
  transitions and any native execution correlations; this module only stores
  complete snapshots and fences updates with Concord's storage revision.

  Every operation requests at most five seconds, optionally shortened by an
  absolute monotonic millisecond `:deadline`. Metadata reads and CAS share that
  budget. Native work cannot be forcibly interrupted and may finish later;
  known successful CAS acknowledgements remain successful after the deadline.
  Conflicts and uncertain outcomes are returned without retrying.
  """

  @prefix "coord/workflow_continuations/"
  @timeout 5_000

  @doc "Create a workflow with a new UUID and revision one after an acknowledged CAS."
  def create(session_id, agent_id, snapshot, opts \\ []) do
    with {:ok, deadline} <- deadline(opts),
         :ok <- validate_uuid(session_id, :invalid_session_id),
         :ok <- validate_uuid(agent_id, :invalid_agent_id),
         :ok <- validate_snapshot(snapshot) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      record = %{
        schema_version: 1,
        id: Ecto.UUID.generate(),
        session_id: session_id,
        agent_id: agent_id,
        revision: 1,
        inserted_at: now,
        updated_at: now,
        snapshot: snapshot
      }

      write(record, 0, deadline)
    end
  end

  @doc "Load a validated workflow snapshot, or return `:not_found`."
  def load(session_id, id, opts \\ []) do
    with {:ok, deadline} <- deadline(opts),
         :ok <- validate_uuid(session_id, :invalid_session_id),
         :ok <- validate_uuid(id, :invalid_workflow_id),
         {:ok, record, _storage_revision} <- read(session_id, id, deadline) do
      {:ok, record}
    end
  end

  @doc "Replace a complete snapshot at the expected logical revision, without retries."
  def commit(session_id, id, expected_revision, snapshot, opts \\ []) do
    with {:ok, deadline} <- deadline(opts),
         :ok <- validate_uuid(session_id, :invalid_session_id),
         :ok <- validate_uuid(id, :invalid_workflow_id),
         :ok <- validate_revision(expected_revision),
         :ok <- validate_snapshot(snapshot),
         {:ok, current, storage_revision} <- read(session_id, id, deadline),
         :ok <- match_revision(current.revision, expected_revision) do
      record = %{
        current
        | revision: expected_revision + 1,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          snapshot: snapshot
      }

      write(record, storage_revision, deadline)
    else
      :not_found -> {:error, :resource_conflict}
      {:error, _} = error -> error
    end
  end

  defp read(session_id, id, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      case Concord.KV.get(key(session_id, id),
             engine: :turso,
             metadata: true,
             timeout: timeout
           ) do
        {:ok, %Concord.KV.Record{value: record, mod_revision: storage_revision}}
        when is_integer(storage_revision) and storage_revision > 0 ->
          with :ok <- validate_record(session_id, id, record) do
            {:ok, record, storage_revision}
          end

        {:ok, _record} ->
          {:error, :invalid_continuation_record}

        {:error, :not_found} ->
          :not_found

        {:error, _} = error ->
          error
      end
    end
  end

  defp write(record, storage_revision, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      case Concord.Turso.compare_and_swap(key(record.session_id, record.id), record,
             mod_revision: storage_revision,
             timeout: timeout
           ) do
        {:ok, %{succeeded: true}} -> {:ok, record}
        {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
        {:ok, _result} -> {:error, :invalid_storage_response}
        {:error, _} = error -> error
      end
    end
  end

  defp validate_record(
         session_id,
         id,
         %{
           schema_version: 1,
           id: id,
           session_id: session_id,
           agent_id: agent_id,
           revision: revision,
           inserted_at: inserted_at,
           updated_at: updated_at,
           snapshot: snapshot
         } = record
       )
       when map_size(record) == 8 and is_integer(revision) and revision > 0 do
    with :ok <- validate_uuid(agent_id, :invalid_continuation_record),
         true <- timestamp?(inserted_at) and timestamp?(updated_at),
         :ok <- validate_snapshot(snapshot) do
      :ok
    else
      _ -> {:error, :invalid_continuation_record}
    end
  end

  defp validate_record(_session_id, _id, _record),
    do: {:error, :invalid_continuation_record}

  defp validate_uuid(id, reason) when is_binary(id) do
    if match?({:ok, ^id}, Ecto.UUID.cast(id)), do: :ok, else: {:error, reason}
  end

  defp validate_uuid(_id, reason), do: {:error, reason}

  defp validate_revision(revision) when is_integer(revision) and revision > 0, do: :ok
  defp validate_revision(_revision), do: {:error, :invalid_revision}

  defp match_revision(revision, revision), do: :ok
  defp match_revision(_current, _expected), do: {:error, :resource_conflict}

  defp validate_snapshot(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    if json?(snapshot), do: :ok, else: {:error, :invalid_snapshot}
  end

  defp validate_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  defp json?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and json?(item)
    end)
  end

  defp json?([]), do: true
  defp json?([head | tail]), do: json?(head) and json_list?(tail)
  defp json?(value) when is_binary(value), do: String.valid?(value)

  defp json?(value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: true

  defp json?(value) when is_float(value),
    do: value >= -1.7976931348623157e308 and value <= 1.7976931348623157e308

  defp json?(_value), do: false

  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json?(head) and json_list?(tail)
  defp json_list?(_tail), do: false

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  defp deadline([]), do: {:ok, System.monotonic_time(:millisecond) + @timeout}

  defp deadline(deadline: deadline) when is_integer(deadline),
    do: {:ok, min(deadline, System.monotonic_time(:millisecond) + @timeout)}

  defp deadline(_opts), do: {:error, :invalid_options}

  defp remaining_timeout(deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end

  defp key(session_id, id), do: @prefix <> session_id <> "/" <> id
end
