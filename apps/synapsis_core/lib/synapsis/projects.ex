defmodule Synapsis.Projects do
  @moduledoc "Public API for project management."

  alias Synapsis.{Repo, Project}
  import Ecto.Query

  def list do
    Project
    |> order_by([p], desc: p.updated_at)
    |> Repo.all()
  end

  def get(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def find_or_create(path) do
    slug = Project.slug_from_path(path)

    %Project{}
    |> Project.changeset(%{path: path, slug: slug})
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: :path,
      returning: true
    )
  end
end
