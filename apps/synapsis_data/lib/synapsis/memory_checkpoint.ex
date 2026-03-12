defmodule Synapsis.MemoryCheckpoint do
  @moduledoc "Serializable execution state for crash recovery (Layer C: Checkpoint Memory)."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_formats ~w(json binary)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_checkpoints" do
    field :run_id, :string
    field :session_id, :string
    field :workflow, :string
    field :node, :string
    field :state_version, :integer
    field :state_format, :string, default: "json"
    field :state_bytea, :binary
    field :state_json, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(run_id session_id workflow node state_version)a
  @optional_fields ~w(state_format state_bytea state_json)a

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:state_format, @valid_formats)
    |> validate_number(:state_version, greater_than_or_equal_to: 1)
  end
end
