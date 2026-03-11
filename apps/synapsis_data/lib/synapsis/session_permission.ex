defmodule Synapsis.SessionPermission do
  @moduledoc "Per-session permission configuration for tool access control."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_permissions" do
    belongs_to :session, Synapsis.Session

    field :mode, Ecto.Enum, values: [:interactive, :autonomous], default: :interactive
    field :allow_write, Ecto.Enum, values: [:allow, :deny, :ask], default: :allow
    field :allow_execute, Ecto.Enum, values: [:allow, :deny, :ask], default: :allow
    field :allow_destructive, Ecto.Enum, values: [:allow, :deny, :ask], default: :ask
    field :tool_overrides, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(session_id)a
  @optional_fields ~w(mode allow_write allow_execute allow_destructive tool_overrides)a

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:session_id)
    |> foreign_key_constraint(:session_id)
  end
end
