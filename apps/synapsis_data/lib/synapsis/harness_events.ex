defmodule Synapsis.HarnessEvents do
  @moduledoc "Repo boundary for harness session events."

  import Ecto.Query
  alias Synapsis.{HarnessEvent, Repo}

  def append(aggregate_id, event_type, payload, opts \\ []) do
    schema_version = Keyword.get(opts, :schema_version, 1)

    Repo.transaction(fn ->
      version = next_version(aggregate_id)

      %HarnessEvent{}
      |> HarnessEvent.changeset(%{
        aggregate_id: aggregate_id,
        version: version,
        event_type: event_type,
        schema_version: schema_version,
        payload: payload
      })
      |> Repo.insert()
      |> case do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def list_for_session(aggregate_id) do
    HarnessEvent
    |> where([event], event.aggregate_id == ^aggregate_id)
    |> order_by([event], asc: event.version)
    |> Repo.all()
  end

  defp next_version(aggregate_id) do
    query =
      from(event in HarnessEvent,
        where: event.aggregate_id == ^aggregate_id,
        select: max(event.version)
      )

    (Repo.one(query) || 0) + 1
  end
end
