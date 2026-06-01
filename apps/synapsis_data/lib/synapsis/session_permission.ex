defmodule Synapsis.SessionPermission do
  @moduledoc """
  Per-session permission configuration for tool access control.

  ADR-006 C4: an `embedded_schema` (no DB table). Persisted as a session-scoped
  Concord entry; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:session_id, :binary_id)

    field(:mode, Ecto.Enum, values: [:interactive, :autonomous], default: :interactive)
    field(:allow_read, Ecto.Enum, values: [:allow, :deny, :ask], default: :allow)
    field(:allow_write, Ecto.Enum, values: [:allow, :deny, :ask], default: :allow)
    field(:allow_execute, Ecto.Enum, values: [:allow, :deny, :ask], default: :allow)
    field(:allow_destructive, Ecto.Enum, values: [:allow, :deny, :ask], default: :ask)
    field(:tool_overrides, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @required_fields ~w(session_id)a
  @optional_fields ~w(mode allow_read allow_write allow_execute allow_destructive tool_overrides)a

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
