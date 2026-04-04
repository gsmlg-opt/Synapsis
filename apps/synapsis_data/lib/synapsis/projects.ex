defmodule Synapsis.Projects do
  @moduledoc "Data context for projects."

  import Ecto.Query
  alias Synapsis.{Project, Repo}

  @spec find_or_create(binary()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create(path) do
    slug = Project.slug_from_path(path)

    %Project{}
    |> Project.changeset(%{path: path, slug: slug, name: slug})
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: :path,
      returning: true
    )
  end

  @spec create(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Project{} |> Project.changeset(attrs) |> Repo.insert()
  end

  @spec get(binary()) :: Project.t() | nil
  def get(id), do: Repo.get(Project, id)

  @spec get!(binary()) :: Project.t()
  def get!(id), do: Repo.get!(Project, id)

  @spec update(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update(project, attrs) do
    project |> Project.changeset(attrs) |> Repo.update()
  end

  @spec list(keyword()) :: [Project.t()]
  def list(opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    query = from(p in Project, order_by: [asc: p.name])

    query =
      if include_archived do
        query
      else
        where(query, [p], p.status != :archived)
      end

    Repo.all(query)
  end

  @spec archive(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Project{status: :archived}) do
    {:error,
     %Project{}
     |> Project.changeset(%{name: "placeholder", path: "/x", slug: "x"})
     |> Ecto.Changeset.add_error(:status, "is already archived")}
  end

  def archive(%Project{} = project) do
    project |> Project.changeset(%{status: :archived}) |> Repo.update()
  end
end
