defmodule Synapsis.SessionTodo do
  @moduledoc "Session-scoped todo/checklist items managed by the agent."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_todos" do
    belongs_to :session, Synapsis.Session

    field :todo_id, :string
    field :content, :string
    field :status, Ecto.Enum, values: [:pending, :in_progress, :completed], default: :pending
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(session_id todo_id content)a
  @optional_fields ~w(status sort_order)a

  def changeset(todo, attrs) do
    todo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:todo_id, max: 255)
    |> unique_constraint([:session_id, :todo_id])
    |> foreign_key_constraint(:session_id)
  end
end
