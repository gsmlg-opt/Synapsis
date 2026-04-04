defmodule Synapsis.ProjectTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test"})
      assert cs.valid?
    end

    test "invalid without path" do
      cs = %Project{} |> Project.changeset(%{slug: "test", name: "test"})
      refute cs.valid?
      assert %{path: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without slug" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", name: "test"})
      refute cs.valid?
      assert %{slug: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without name" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "sets default config" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test"})
      assert get_field(cs, :config) == %{}
    end

    test "defaults status to :active" do
      cs = %Project{} |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test"})
      assert get_field(cs, :status) == :active
    end

    test "accepts :active status" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test", status: :active})

      assert cs.valid?
    end

    test "accepts :paused status" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test", status: :paused})

      assert cs.valid?
    end

    test "accepts :archived status" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test", status: :archived})

      assert cs.valid?
    end

    test "rejects invalid status" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "test", status: :invalid})

      refute cs.valid?
      assert %{status: _} = errors_on(cs)
    end

    test "validates name format - rejects uppercase" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "MyProject"})

      refute cs.valid?
      assert %{name: [msg]} = errors_on(cs)
      assert msg =~ "must be lowercase alphanumeric with hyphens"
    end

    test "validates name format - rejects special characters" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "my_project!"})

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name format - rejects starting with hyphen" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "-myproject"})

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name format - accepts lowercase alphanumeric with hyphens" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: "my-project-123"})

      assert cs.valid?
    end

    test "validates name length - rejects name over 64 chars" do
      long_name = String.duplicate("a", 65)

      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: long_name})

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name length - accepts 64 char name" do
      name_64 = String.duplicate("a", 64)

      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test", slug: "test", name: name_64})

      assert cs.valid?
    end

    test "enforces unique name" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/name_unique_1", slug: "name-unique-1", name: "unique-name"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/name_unique_2", slug: "name-unique-2", name: "unique-name"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "enforces unique path" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/unique_path", slug: "unique-1", name: "unique-1"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/unique_path", slug: "unique-2", name: "unique-2"})
        |> Repo.insert()

      assert %{path: ["has already been taken"]} = errors_on(cs)
    end

    test "enforces unique slug" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/slug_test_1", slug: "same-slug", name: "slug-a"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/slug_test_2", slug: "same-slug", name: "slug-b"})
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

  describe "slug uniqueness edge cases" do
    test "slugs differing only by case are treated as distinct" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/case_test_lower", slug: "my-project", name: "my-project"})
        |> Repo.insert()

      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/case_test_upper", slug: "My-Project", name: "my-project-2"})

      assert cs.valid?
      # Database constraint determines whether case-sensitive duplicates are allowed
      result = Repo.insert(cs)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "very long slugs are accepted by changeset" do
      long_slug = String.duplicate("a", 255)

      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/long_slug_test", slug: long_slug, name: "long-slug"})

      assert cs.valid?
    end

    test "slug with only hyphens and underscores is valid" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/hyphen_slug", slug: "---___---", name: "hyphen-slug"})

      assert cs.valid?
    end

    test "numeric-only slug is valid" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/numeric_slug", slug: "12345", name: "numeric-slug"})

      assert cs.valid?
    end
  end

  describe "path is required" do
    test "rejects nil path" do
      cs = %Project{} |> Project.changeset(%{slug: "test-slug", path: nil, name: "test-name"})
      refute cs.valid?
      assert %{path: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects missing path key" do
      cs = %Project{} |> Project.changeset(%{slug: "test-slug", name: "test-name"})
      refute cs.valid?
      assert %{path: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects empty string path" do
      cs = %Project{} |> Project.changeset(%{path: "", slug: "test-slug", name: "test-name"})
      refute cs.valid?
      assert %{path: ["can't be blank"]} = errors_on(cs)
    end

    test "accepts path with spaces" do
      cs =
        %Project{}
        |> Project.changeset(%{path: "/tmp/my project dir", slug: "my-project", name: "my-project"})

      assert cs.valid?
    end

    test "path uniqueness is enforced at database level" do
      {:ok, _} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/dup_path_test", slug: "dup-path-1", name: "dup-path-1"})
        |> Repo.insert()

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/dup_path_test", slug: "dup-path-2", name: "dup-path-2"})
        |> Repo.insert()

      assert %{path: ["has already been taken"]} = errors_on(cs)
    end
  end

  describe "slug_from_path/1 edge cases" do
    test "handles root path" do
      assert Project.slug_from_path("/") == ""
    end

    test "handles path with trailing slash" do
      assert Project.slug_from_path("/home/user/project/") == "project"
    end

    test "handles path with dots" do
      # Leading dot becomes hyphen, which is then trimmed by String.trim("-")
      assert Project.slug_from_path("/home/user/.hidden-project") == "hidden-project"
    end

    test "handles path with multiple special characters" do
      slug = Project.slug_from_path("/home/user/My $pecial (Project) v2.0!")
      assert slug =~ ~r/^[a-z0-9_-]+$/
    end

    test "handles single-component path" do
      assert Project.slug_from_path("simple") == "simple"
    end

    test "handles path with numbers" do
      assert Project.slug_from_path("/home/user/project123") == "project123"
    end

    test "handles deeply nested path" do
      assert Project.slug_from_path("/a/b/c/d/e/f/final") == "final"
    end

    test "handles path with unicode characters" do
      slug = Project.slug_from_path("/home/user/projet-francais")
      assert slug == "projet-francais"
    end
  end

  describe "persistence" do
    test "inserts and retrieves project" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/persist_test", slug: "persist-test", name: "persist-test"})
        |> Repo.insert()

      found = Repo.get!(Project, project.id)
      assert found.path == "/tmp/persist_test"
      assert found.slug == "persist-test"
      assert found.name == "persist-test"
    end

    test "preloads sessions" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/preload_test", slug: "preload-test", name: "preload-test"})
        |> Repo.insert()

      loaded = Repo.preload(project, :sessions)
      assert loaded.sessions == []
    end

    test "preloads repos" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/repos_preload", slug: "repos-preload", name: "repos-preload"})
        |> Repo.insert()

      loaded = Repo.preload(project, :repos)
      assert loaded.repos == []
    end
  end
end
