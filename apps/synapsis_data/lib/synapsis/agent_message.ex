defmodule Synapsis.AgentMessage do
  @moduledoc """
  Agent-to-agent message for reliable delivery.

  ADR-006 C4: an `embedded_schema` (no DB table). Messages are node-local
  coordination data persisted in Concord via `Synapsis.AgentMessages`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @types ~w(request response notification delegation handoff completion)
  @statuses ~w(delivered read acknowledged expired)

  embedded_schema do
    field(:ref, :string)
    field(:from_agent_id, :string)
    field(:to_agent_id, :string)
    field(:type, :string, default: "notification")
    field(:in_reply_to, :binary_id)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "delivered")
    field(:session_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @required_fields ~w(ref from_agent_id to_agent_id)a
  @optional_fields ~w(id type in_reply_to payload status session_id expires_at)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
  end
end
