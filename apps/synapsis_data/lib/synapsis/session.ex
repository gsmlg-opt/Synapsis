defmodule Synapsis.Session do
  @moduledoc """
  Session entity — an agent-owned conversation workspace.

  ADR-006 C4: an `embedded_schema` (no DB table). Sessions are persisted in the
  node-local Concord store via `Synapsis.Session.Store`; this struct is the
  in-memory shape and changeset/validation surface. IDs are assigned by the
  persistence context (see `Synapsis.Sessions`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:title, :string)
    field(:agent, :string, default: "main")
    field(:provider, :string)
    field(:model, :string)
    field(:status, :string, default: "idle")
    field(:config, :map, default: %{})
    field(:debug, :boolean, default: false)

    # Associations are denormalized in C4: messages/turns live in Concord under
    # the session key; permissions/todos are session-scoped Concord entries.
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @valid_statuses ~w(idle streaming tool_executing error)

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:id, :title, :agent, :provider, :model, :status, :config, :debug])
    |> validate_required([:provider, :model, :agent])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:title, max: 500)
    |> validate_length(:agent, min: 1, max: 255)
    |> validate_length(:provider, max: 255)
    |> validate_length(:model, max: 255)
  end

  def status_changeset(session, status) do
    session
    |> change(status: status)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
