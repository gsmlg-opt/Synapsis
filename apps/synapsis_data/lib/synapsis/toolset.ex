defmodule Synapsis.Toolset do
  @moduledoc """
  A named set of built-in and MCP tool identifiers assignable to agents.

  ADR-006 C4: an `embedded_schema` (no DB table). Toolsets persist in the
  file-backed `Config.Store` (`toolsets.toml`) via `Synapsis.Toolsets`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:name, :string)
    field(:description, :string)
    field(:tool_names, {:array, :string}, default: [])
    field(:is_builtin, :boolean, default: false)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(toolset, attrs) do
    toolset
    |> cast(attrs, [:id, :name, :description, :tool_names, :is_builtin])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> validate_length(:description, max: 2_000)
  end
end
