defmodule Synapsis.Project do
  @moduledoc "Project entity - maps to a project directory."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:path, :string)
    field(:slug, :string)
    field(:config, :map, default: %{})

    has_many(:sessions, Synapsis.Session)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:path, :slug, :config])
    |> validate_required([:path, :slug])
    |> unique_constraint(:path)
    |> unique_constraint(:slug)
  end

  def slug_from_path(path) do
    path
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.trim("-")
  end
end
