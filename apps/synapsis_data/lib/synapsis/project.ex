defmodule Synapsis.Project do
  @moduledoc "Project entity - maps to a project directory."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:path, :string)
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:status, Ecto.Enum, values: [:active, :paused, :archived], default: :active)
    field(:config, :map, default: %{})
    field(:metadata, :map, default: %{})

    has_many(:sessions, Synapsis.Session)
    has_many(:repos, Synapsis.RepoRecord)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:path, :slug, :name, :description, :status, :config, :metadata])
    |> validate_required([:path, :slug, :name])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name)
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
