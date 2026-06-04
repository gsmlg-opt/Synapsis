defmodule Synapsis.AgentEvent do
  @moduledoc """
  Append-only event log for agent orchestration.

  ADR-006 C4: an `embedded_schema` (no DB table). Agent events are node-local
  coordination data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:event_type, :string)
    field(:agent_id, :string)
    field(:work_id, :string)
    field(:payload, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :event_type, :agent_id, :work_id, :payload])
    |> validate_required([:event_type])
  end
end
