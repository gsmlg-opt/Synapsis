defmodule Synapsis.AgentMessage do
  @moduledoc "Persistent agent-to-agent message for reliable delivery."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(request response notification delegation handoff completion)
  @statuses ~w(delivered read acknowledged expired)

  schema "agent_messages" do
    field(:ref, :string)
    field(:from_agent_id, :string)
    field(:to_agent_id, :string)
    field(:type, :string, default: "notification")
    field(:in_reply_to, :binary_id)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "delivered")
    field(:project_id, :binary_id)
    field(:session_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(ref from_agent_id to_agent_id)a
  @optional_fields ~w(type in_reply_to payload status project_id session_id expires_at)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:from_agent_id, max: 255)
    |> validate_length(:to_agent_id, max: 255)
  end

  def mark_read_changeset(message) do
    change(message, status: "read")
  end

  def mark_acknowledged_changeset(message) do
    change(message, status: "acknowledged")
  end

  def mark_expired_changeset(message) do
    change(message, status: "expired")
  end
end
