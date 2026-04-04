defmodule Synapsis.RepoRecordTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo, RepoRecord}

  defp insert_project(attrs \\ %{}) do
    defaults = %{path: "/tmp/repo-test-#{System.unique_integer()}", slug: "repo-test-#{System.unique_integer([:positive])}", name: "repo-test-#{System.unique_integer([:positive])}"}

    {:ok, project} =
      %Project{}
      |> Project.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    project
  end

  describe "changeset/2" do
    test "valid with required fields" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my-repo",
          bare_path: "/repos/my-repo.git"
        })

      assert cs.valid?
    end

    test "requires project_id" do
      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{name: "my-repo", bare_path: "/repos/my-repo.git"})

      refute cs.valid?
      assert %{project_id: ["can't be blank"]} = errors_on(cs)
    end

    test "requires name" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{project_id: project.id, bare_path: "/repos/my-repo.git"})

      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "requires bare_path" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{project_id: project.id, name: "my-repo"})

      refute cs.valid?
      assert %{bare_path: ["can't be blank"]} = errors_on(cs)
    end

    test "validates name format - rejects uppercase" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "MyRepo",
          bare_path: "/repos/my-repo.git"
        })

      refute cs.valid?
      assert %{name: [msg]} = errors_on(cs)
      assert msg =~ "must be lowercase alphanumeric with hyphens"
    end

    test "validates name format - rejects underscores" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my_repo",
          bare_path: "/repos/my-repo.git"
        })

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name format - rejects starting with hyphen" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "-myrepo",
          bare_path: "/repos/my-repo.git"
        })

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name format - accepts lowercase alphanumeric with hyphens" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my-repo-123",
          bare_path: "/repos/my-repo.git"
        })

      assert cs.valid?
    end

    test "validates name length - rejects name over 64 chars" do
      project = insert_project()
      long_name = String.duplicate("a", 65)

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: long_name,
          bare_path: "/repos/my-repo.git"
        })

      refute cs.valid?
      assert %{name: _} = errors_on(cs)
    end

    test "validates name length - accepts 64 char name" do
      project = insert_project()
      name_64 = String.duplicate("a", 64)

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: name_64,
          bare_path: "/repos/my-repo.git"
        })

      assert cs.valid?
    end

    test "defaults default_branch to 'main'" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my-repo",
          bare_path: "/repos/my-repo.git"
        })

      assert get_field(cs, :default_branch) == "main"
    end

    test "accepts custom default_branch" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my-repo",
          bare_path: "/repos/my-repo.git",
          default_branch: "develop"
        })

      assert cs.valid?
      assert get_field(cs, :default_branch) == "develop"
    end

    test "defaults status to :active" do
      project = insert_project()

      cs =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "my-repo",
          bare_path: "/repos/my-repo.git"
        })

      assert get_field(cs, :status) == :active
    end

    test "enforces unique name within project" do
      project = insert_project()

      {:ok, _} =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "dup-repo",
          bare_path: "/repos/dup-repo-1.git"
        })
        |> Repo.insert()

      {:error, cs} =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project.id,
          name: "dup-repo",
          bare_path: "/repos/dup-repo-2.git"
        })
        |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(cs)
    end

    test "allows same repo name in different projects" do
      project1 = insert_project()
      project2 = insert_project()

      {:ok, _} =
        %RepoRecord{}
        |> RepoRecord.changeset(%{
          project_id: project1.id,
          name: "shared-name",
          bare_path: "/repos/shared-1.git"
        })
        |> Repo.insert()

      assert {:ok, _} =
               %RepoRecord{}
               |> RepoRecord.changeset(%{
                 project_id: project2.id,
                 name: "shared-name",
                 bare_path: "/repos/shared-2.git"
               })
               |> Repo.insert()
    end
  end
end
