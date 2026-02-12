defmodule Synapsis.Message do
  @moduledoc "Message entity - a single turn in a conversation."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:role, :string)
    field(:parts, {:array, Synapsis.Part}, default: [])
    field(:token_count, :integer, default: 0)

    belongs_to(:session, Synapsis.Session)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_roles ~w(user assistant system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :parts, :token_count, :session_id])
    |> validate_required([:role, :session_id])
    |> validate_inclusion(:role, @valid_roles)
    |> foreign_key_constraint(:session_id)
  end
end
