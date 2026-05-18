defmodule Synapsis.Toolset do
  @moduledoc "A named set of built-in and MCP tool identifiers assignable to agents."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "toolsets" do
    field(:name, :string)
    field(:description, :string)
    field(:tool_names, {:array, :string}, default: [])
    field(:is_builtin, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(toolset, attrs) do
    toolset
    |> cast(attrs, [:name, :description, :tool_names, :is_builtin])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint(:name)
  end
end
