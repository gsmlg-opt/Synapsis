defmodule Synapsis.SessionTodo do
  @moduledoc """
  Session-scoped todo/checklist items managed by the agent.

  ADR-006 C4: an `embedded_schema` (no DB table). Todos are session-scoped Concord
  data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:session_id, :binary_id)
    field(:todo_id, :string)
    field(:content, :string)
    field(:status, Ecto.Enum, values: [:pending, :in_progress, :completed], default: :pending)
    field(:sort_order, :integer, default: 0)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @required_fields ~w(session_id todo_id content)a
  @optional_fields ~w(id status sort_order)a

  def changeset(todo, attrs) do
    todo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:todo_id, max: 255)
  end
end
