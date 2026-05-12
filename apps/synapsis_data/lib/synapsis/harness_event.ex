defmodule Synapsis.HarnessEvent do
  @moduledoc "Durable event-log row for the harness session aggregate."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "harness_events" do
    field(:aggregate_id, :binary_id)
    field(:version, :integer)
    field(:event_type, :string)
    field(:schema_version, :integer, default: 1)
    field(:payload, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:aggregate_id, :version, :event_type, :schema_version, :payload])
    |> validate_required([:aggregate_id, :version, :event_type, :schema_version, :payload])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:schema_version, greater_than: 0)
    |> unique_constraint([:aggregate_id, :version],
      name: :harness_events_aggregate_id_version_index
    )
  end
end
