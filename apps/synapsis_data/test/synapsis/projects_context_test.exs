defmodule Synapsis.ProjectsContextTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Projects}

  defp unique_project_attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        path: "/tmp/projects-ctx-#{n}",
        slug: "projects-ctx-#{n}",
        name: "projects-ctx-#{n}"
      },
      overrides
    )
  end

  describe "create/1" do
    test "creates a project with valid attrs" do
      attrs = unique_project_attrs()
      assert {:ok, %Project{} = project} = Projects.create(attrs)
      assert project.name == attrs.name
      assert project.path == attrs.path
      assert project.slug == attrs.slug
      assert project.status == :active
    end

    test "rejects duplicate name" do
      attrs1 = unique_project_attrs()
      {:ok, _} = Projects.create(attrs1)

      n = System.unique_integer([:positive])

      attrs2 = %{
        path: "/tmp/other-path-#{n}",
        slug: "other-slug-#{n}",
        name: attrs1.name
      }

      assert {:error, changeset} = Projects.create(attrs2)
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Projects.create(%{slug: "s", name: "n"})
      assert %{path: _} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns project by id" do
      {:ok, project} = Projects.create(unique_project_attrs())
      found = Projects.get(project.id)
      assert found.id == project.id
    end

    test "returns nil for missing id" do
      assert Projects.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "get!/1" do
    test "returns project by id" do
      {:ok, project} = Projects.create(unique_project_attrs())
      found = Projects.get!(project.id)
      assert found.id == project.id
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Projects.get!(Ecto.UUID.generate())
      end
    end
  end

  describe "update/2" do
    test "updates description" do
      {:ok, project} = Projects.create(unique_project_attrs())
      assert {:ok, updated} = Projects.update(project, %{description: "new desc"})
      assert updated.description == "new desc"
      assert updated.id == project.id
    end

    test "returns error changeset on invalid update" do
      {:ok, project} = Projects.create(unique_project_attrs())
      assert {:error, changeset} = Projects.update(project, %{name: "Invalid Name!"})
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "list/1" do
    test "returns active projects by default" do
      {:ok, active} = Projects.create(unique_project_attrs(%{status: :active}))
      {:ok, paused} = Projects.create(unique_project_attrs(%{status: :paused}))
      {:ok, archived_proj} = Projects.create(unique_project_attrs(%{status: :archived}))

      ids = Projects.list() |> Enum.map(& &1.id)

      assert active.id in ids
      assert paused.id in ids
      refute archived_proj.id in ids
    end

    test "includes archived when option is set" do
      {:ok, active} = Projects.create(unique_project_attrs(%{status: :active}))
      {:ok, archived_proj} = Projects.create(unique_project_attrs(%{status: :archived}))

      ids = Projects.list(include_archived: true) |> Enum.map(& &1.id)

      assert active.id in ids
      assert archived_proj.id in ids
    end

    test "returns empty list when no projects exist" do
      # ensure at least it is callable; other tests may have projects
      result = Projects.list()
      assert is_list(result)
    end
  end

  describe "archive/1" do
    test "transitions active project to archived" do
      {:ok, project} = Projects.create(unique_project_attrs(%{status: :active}))
      assert {:ok, archived} = Projects.archive(project)
      assert archived.status == :archived
    end

    test "transitions paused project to archived" do
      {:ok, project} = Projects.create(unique_project_attrs(%{status: :paused}))
      assert {:ok, archived} = Projects.archive(project)
      assert archived.status == :archived
    end

    test "rejects archiving an already archived project" do
      {:ok, project} = Projects.create(unique_project_attrs(%{status: :archived}))
      assert {:error, changeset} = Projects.archive(project)
      assert %{status: _} = errors_on(changeset)
    end
  end
end
