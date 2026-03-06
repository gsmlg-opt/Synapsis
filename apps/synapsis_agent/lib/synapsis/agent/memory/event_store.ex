defmodule Synapsis.Agent.Memory.EventStore do
  @moduledoc """
  DB-backed append-only event log for agent orchestration.
  Delegates to `Synapsis.AgentEvents` for persistence.
  """

  alias Synapsis.Agent.Memory.Event

  @spec append(map()) :: :ok | {:error, term()}
  def append(attrs) when is_map(attrs) do
    Synapsis.AgentEvents.append(attrs)
  end

  @spec list(keyword()) :: [Event.t()]
  def list(filters \\ []) do
    filters
    |> Synapsis.AgentEvents.list()
    |> Enum.map(&to_event/1)
  end

  defp to_event(%Synapsis.AgentEvent{} = row) do
    %Event{
      id: row.id,
      event_type: String.to_existing_atom(row.event_type),
      timestamp: row.inserted_at,
      project_id: row.project_id,
      work_id: row.work_id,
      payload: row.payload || %{}
    }
  end
end
