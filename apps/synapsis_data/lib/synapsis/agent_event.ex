defmodule Synapsis.AgentEvent do
  @moduledoc "Append-only event log for agent orchestration."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_events" do
    field :event_type, :string
    field :project_id, :string
    field :work_id, :string
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :project_id, :work_id, :payload])
    |> validate_required([:event_type])
  end
end
