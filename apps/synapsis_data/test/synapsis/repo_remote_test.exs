defmodule Synapsis.RepoRemoteTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo, RepoRecord, RepoRemote}

  defp insert_project() do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/remote-test-#{n}", slug: "remote-test-#{n}", name: "remote-test-#{n}"})
      |> Repo.insert()

    project
  end

  defp insert_repo(project) do
    n = System.unique_integer([:positive])

    {:ok, repo} =
      %RepoRecord{}
      |> RepoRecord.changeset(%{
        project_id: project.id,
        name: "repo-#{n}",
        bare_path: "/repos/repo-#{n}.git"
      })
      |> Repo.insert()

    repo
  end

  describe "changeset/2" do
    test "valid with HTTPS URL" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "https://github.com/user/repo.git"
        })

      assert cs.valid?
    end

    test "valid with SSH URL" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "git@github.com:user/repo.git"
        })

      assert cs.valid?
    end

    test "requires repo_id" do
      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{name: "origin", url: "https://github.com/user/repo.git"})

      refute cs.valid?
      assert %{repo_id: ["can't be blank"]} = errors_on(cs)
    end

    test "requires name" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{repo_id: repo.id, url: "https://github.com/user/repo.git"})

      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "requires url" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{repo_id: repo.id, name: "origin"})

      refute cs.valid?
      assert %{url: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects invalid URL format" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "not-a-valid-url"
        })

      refute cs.valid?
      assert %{url: [msg]} = errors_on(cs)
      assert msg =~ "must be a valid HTTPS or SSH URL"
    end

    test "rejects ftp URL" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "ftp://example.com/repo.git"
        })

      refute cs.valid?
      assert %{url: _} = errors_on(cs)
    end

    test "defaults is_primary to false" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "https://github.com/user/repo.git"
        })

      assert get_field(cs, :is_primary) == false
    end

    test "accepts optional push_url" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "https://github.com/user/repo.git",
          push_url: "git@github.com:user/repo.git"
        })

      assert cs.valid?
    end

    test "enforces unique name within repo" do
      project = insert_project()
      repo = insert_repo(project)

      {:ok, _} =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "https://github.com/user/repo.git"
        })
        |> Repo.insert()

      {:error, cs} =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo.id,
          name: "origin",
          url: "https://gitlab.com/user/repo.git"
        })
        |> Repo.insert()

      assert %{repo_id: ["has already been taken"]} = errors_on(cs)
    end

    test "allows same remote name in different repos" do
      project = insert_project()
      repo1 = insert_repo(project)
      repo2 = insert_repo(project)

      {:ok, _} =
        %RepoRemote{}
        |> RepoRemote.changeset(%{
          repo_id: repo1.id,
          name: "origin",
          url: "https://github.com/user/repo1.git"
        })
        |> Repo.insert()

      assert {:ok, _} =
               %RepoRemote{}
               |> RepoRemote.changeset(%{
                 repo_id: repo2.id,
                 name: "origin",
                 url: "https://github.com/user/repo2.git"
               })
               |> Repo.insert()
    end
  end
end
