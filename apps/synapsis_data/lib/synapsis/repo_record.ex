defmodule Synapsis.RepoRecord do
  @moduledoc "Git repository entity. Named RepoRecord to avoid conflict with Synapsis.Repo (the Ecto Repo)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "repos" do
    field(:name, :string)
    field(:bare_path, :string)
    field(:default_branch, :string, default: "main")
    field(:status, Ecto.Enum, values: [:active, :archived], default: :active)
    field(:metadata, :map, default: %{})

    belongs_to(:project, Synapsis.Project)
    has_many(:remotes, Synapsis.RepoRemote, foreign_key: :repo_id)
    has_many(:worktrees, Synapsis.RepoWorktree, foreign_key: :repo_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:project_id, :name, :bare_path, :default_branch, :status, :metadata])
    |> validate_required([:project_id, :name, :bare_path])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_length(:name, min: 1, max: 64)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :name])
  end
end
