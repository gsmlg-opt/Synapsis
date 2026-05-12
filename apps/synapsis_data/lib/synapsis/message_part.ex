defmodule Synapsis.MessagePart do
  @moduledoc "Row-level durable part projection for harness messages."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(text reasoning file tool agent step_start step_finish snapshot image)

  schema "parts" do
    belongs_to(:session, Synapsis.Session)
    belongs_to(:message, Synapsis.Message)

    field(:ordinal, :integer)
    field(:type, :string)
    field(:data, :map, default: %{})
    field(:deleted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(part, attrs) do
    part
    |> cast(attrs, [:session_id, :message_id, :ordinal, :type, :data, :deleted_at])
    |> validate_required([:session_id, :message_id, :ordinal, :type, :data])
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:message_id, :ordinal], name: :parts_message_id_ordinal_index)
  end
end
