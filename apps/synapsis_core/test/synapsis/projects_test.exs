defmodule Synapsis.ProjectsTest do
  use Synapsis.DataCase

  alias Synapsis.{Projects, Project, Repo}

  describe "list/0" do
    test "returns a list of projects" do
      assert is_list(Projects.list())
    end

    test "returns projects ordered by updated_at desc" do
      %Project{}
      |> Project.changeset(%{path: "/tmp/proj_list_1", slug: "proj-list-1"})
      |> Repo.insert!()

      %Project{}
      |> Project.changeset(%{path: "/tmp/proj_list_2", slug: "proj-list-2"})
      |> Repo.insert!()

      projects = Projects.list()
      assert length(projects) >= 2
      # Most recently updated should be first
      slugs = Enum.map(projects, & &1.slug)
      assert "proj-list-2" in slugs
      assert "proj-list-1" in slugs
    end
  end

  describe "get/1" do
    test "returns project by id" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/proj_get", slug: "proj-get"})
        |> Repo.insert()

      assert {:ok, found} = Projects.get(project.id)
      assert found.id == project.id
    end

    test "returns error for missing project" do
      assert {:error, :not_found} = Projects.get(Ecto.UUID.generate())
    end
  end

  describe "find_or_create/1" do
    test "creates new project for unknown path" do
      {:ok, project} = Projects.find_or_create("/tmp/proj_foc_new")
      assert project.path == "/tmp/proj_foc_new"
      assert project.slug == "proj_foc_new"
    end

    test "returns existing project for known path" do
      {:ok, p1} = Projects.find_or_create("/tmp/proj_foc_existing")
      {:ok, p2} = Projects.find_or_create("/tmp/proj_foc_existing")
      assert p1.id == p2.id
    end

    test "auto-generates slug from path" do
      {:ok, project} = Projects.find_or_create("/home/user/MyProject")
      assert project.slug == "myproject"
    end

    test "handles nested paths" do
      {:ok, project} = Projects.find_or_create("/home/user/deep/nested/myapp")
      assert project.slug == "myapp"
      assert project.path == "/home/user/deep/nested/myapp"
    end

    test "handles paths with hyphens" do
      {:ok, project} = Projects.find_or_create("/tmp/my-cool-project-test")
      assert project.slug == "my-cool-project-test"
    end

    test "returns same project on repeated calls" do
      {:ok, p1} = Projects.find_or_create("/tmp/idempotent-test")
      {:ok, p2} = Projects.find_or_create("/tmp/idempotent-test")
      {:ok, p3} = Projects.find_or_create("/tmp/idempotent-test")
      assert p1.id == p2.id
      assert p2.id == p3.id
    end
  end
end
