defmodule Synapsis.ProjectTest do
  use Synapsis.DataCase

  alias Synapsis.{Project, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test"})
      assert cs.valid?
    end

    test "invalid without path" do
      cs = %Project{} |> Project.changeset(%{slug: "test"})
      refute cs.valid?
      assert %{path: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without slug" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test"})
      refute cs.valid?
      assert %{slug: ["can't be blank"]} = errors_on(cs)
    end

    test "sets default config" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test"})
      assert get_field(cs, :config) == %{}
    end

    test "enforces unique path" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/unique_path", slug: "unique-1"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/unique_path", slug: "unique-2"})
        |> Repo.insert()

      assert %{path: ["has already been taken"]} = errors_on(cs)
    end

    test "enforces unique slug" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/slug_test_1", slug: "same-slug"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/slug_test_2", slug: "same-slug"})
        |> Repo.insert()

      assert %{slug: ["has already been taken"]} = errors_on(cs)
    end
  end

  describe "slug_from_path/1" do
    test "extracts basename and lowercases" do
      assert Project.slug_from_path("/home/user/MyProject") == "myproject"
    end

    test "replaces non-alphanumeric with hyphens and trims trailing dash" do
      slug = Project.slug_from_path("/home/user/My Cool Project!")
      assert slug == "my-cool-project"
    end

    test "handles simple paths" do
      assert Project.slug_from_path("/tmp/test") == "test"
    end

    test "handles paths with hyphens and underscores" do
      assert Project.slug_from_path("/home/user/my-cool_project") == "my-cool_project"
    end
  end

  describe "persistence" do
    test "inserts and retrieves project" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/persist_test", slug: "persist-test"})
        |> Repo.insert()

      found = Repo.get!(Project, project.id)
      assert found.path == "/tmp/persist_test"
      assert found.slug == "persist-test"
    end

    test "preloads sessions" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/preload_test", slug: "preload-test"})
        |> Repo.insert()

      loaded = Repo.preload(project, :sessions)
      assert loaded.sessions == []
    end
  end
end
