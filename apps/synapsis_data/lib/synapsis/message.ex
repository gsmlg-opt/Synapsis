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

  @doc "List all messages for a session, ordered by insertion time."
  @spec list_by_session(String.t()) :: [%__MODULE__{}]
  def list_by_session(session_id) do
    import Ecto.Query

    __MODULE__
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Synapsis.Repo.all()
  end
end
