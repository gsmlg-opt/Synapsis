defmodule Synapsis.Goal.Store do
  @moduledoc """
  Durable, complete Goal snapshots keyed by canonical persistent Session UUID.

  The agent layer owns the opaque record and its transitions. CAS checks the
  previous logical revision and Goal identity, then atomically fences the write
  against the observed Concord storage revision. Clearing retains a tombstone;
  this store deliberately has no delete operation.

  Metadata read and CAS share one requested five-second budget. Native work may
  finish later; a successful CAS acknowledgement is never converted to timeout.
  """

  @prefix "coord/goals/threads/"
  @timeout 5_000

  def load(thread_id) do
    with :ok <- validate_thread(thread_id) do
      case Concord.KV.get(key(thread_id), engine: :turso, timeout: @timeout) do
        {:ok, record} ->
          with :ok <- validate_record(thread_id, record), do: {:ok, record}

        {:error, :not_found} ->
          :not_found

        {:error, _} = error ->
          error
      end
    end
  end

  def compare_and_swap(thread_id, expected_revision, expected_goal_id, next_record)
      when is_integer(expected_revision) and expected_revision >= 0 and
             (is_binary(expected_goal_id) or is_nil(expected_goal_id)) do
    with :ok <- validate_thread(thread_id),
         :ok <- validate_record(thread_id, next_record) do
      deadline = System.monotonic_time(:millisecond) + @timeout
      committed = Map.put(next_record, :revision, expected_revision + 1)

      with {:ok, timeout} <- remaining_timeout(deadline) do
        case Concord.KV.get(key(thread_id), engine: :turso, metadata: true, timeout: timeout) do
          {:error, :not_found} when expected_revision == 0 and is_nil(expected_goal_id) ->
            commit(thread_id, committed, 0, deadline)

          {:ok, %Concord.KV.Record{value: current, mod_revision: storage_revision}} ->
            with :ok <- validate_record(thread_id, current) do
              if current.revision == expected_revision and goal_id(current) == expected_goal_id do
                commit(thread_id, committed, storage_revision, deadline)
              else
                {:error, :resource_conflict}
              end
            end

          {:error, :not_found} ->
            {:error, :resource_conflict}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  def compare_and_swap(_thread, _revision, _goal_id, _record),
    do: {:error, :invalid_goal_record}

  defp commit(thread_id, record, storage_revision, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      case Concord.Turso.compare_and_swap(key(thread_id), record,
             mod_revision: storage_revision,
             timeout: timeout
           ) do
        {:ok, %{succeeded: true}} -> {:ok, record}
        {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
        {:error, _} = error -> error
      end
    end
  end

  defp validate_thread(thread_id) when is_binary(thread_id) do
    if match?({:ok, ^thread_id}, Ecto.UUID.cast(thread_id)),
      do: :ok,
      else: {:error, :invalid_thread_id}
  end

  defp validate_thread(_), do: {:error, :invalid_thread_id}

  defp validate_record(thread_id, %{thread_id: thread_id, revision: revision, goal: goal})
       when is_integer(revision) and revision >= 0 do
    case goal do
      nil -> :ok
      %{thread_id: ^thread_id, goal_id: id} when is_binary(id) -> :ok
      _ -> {:error, :invalid_goal_record}
    end
  end

  defp validate_record(_thread_id, _record), do: {:error, :invalid_goal_record}

  defp goal_id(%{goal: nil}), do: nil
  defp goal_id(%{goal: %{goal_id: id}}), do: id
  defp key(thread_id), do: @prefix <> thread_id

  defp remaining_timeout(deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end
end
