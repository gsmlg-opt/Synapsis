defmodule Synapsis.Agent.Runtime.GoalStore do
  @moduledoc "Durable native Goal records using stable Session UUIDs and local storage."
  @behaviour Backplane.AgentRuntime.Goal.Store

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Goal.State
  alias Synapsis.Goal.Store, as: DataStore

  @impl true
  def load(:local, thread_id) do
    case DataStore.load(thread_id) do
      {:ok, record} -> {:ok, record}
      :not_found -> State.new(thread_id, [])
      {:error, reason} -> failure(reason)
    end
  end

  @impl true
  def compare_and_swap(:local, thread_id, expected_revision, expected_goal_id, next_record) do
    case DataStore.compare_and_swap(thread_id, expected_revision, expected_goal_id, next_record) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> failure(reason)
    end
  end

  defp failure(:resource_conflict),
    do: {:error, Error.new(:resource_conflict, "goal revision or identity conflict")}

  defp failure(reason) when reason in [:invalid_thread_id, :invalid_goal_record],
    do: {:error, Error.new(:validation, "invalid goal record or thread identity")}

  defp failure(reason),
    do: {:error, Error.new(:execution_failure, "goal storage failed", details: %{reason: reason})}
end
