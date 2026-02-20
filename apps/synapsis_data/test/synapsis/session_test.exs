defmodule Synapsis.SessionTest do
  use Synapsis.DataCase

  alias Synapsis.{Session, Project, Repo}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/session_test_#{:rand.uniform(100_000)}", slug: "session-test-#{:rand.uniform(100_000)}"})
      |> Repo.insert()

    %{project: project}
  end

  describe "changeset/2" do
    test "valid changeset with required fields", %{project: project} do
      cs =
        %Session{}
        |> Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          project_id: project.id
        })

      assert cs.valid?
    end

    test "invalid without provider", %{project: project} do
      cs = %Session{} |> Session.changeset(%{model: "test", project_id: project.id})
      refute cs.valid?
      assert %{provider: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without model", %{project: project} do
      cs = %Session{} |> Session.changeset(%{provider: "test", project_id: project.id})
      refute cs.valid?
      assert %{model: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without project_id" do
      cs = %Session{} |> Session.changeset(%{provider: "test", model: "test"})
      refute cs.valid?
      assert %{project_id: ["can't be blank"]} = errors_on(cs)
    end

    test "validates status inclusion", %{project: project} do
      cs =
        %Session{}
        |> Session.changeset(%{
          provider: "anthropic",
          model: "test",
          project_id: project.id,
          status: "invalid_status"
        })

      refute cs.valid?
      assert %{status: [_]} = errors_on(cs)
    end

    test "validates agent inclusion", %{project: project} do
      cs =
        %Session{}
        |> Session.changeset(%{
          provider: "anthropic",
          model: "test",
          project_id: project.id,
          agent: "nonexistent_agent"
        })

      refute cs.valid?
      assert %{agent: [_]} = errors_on(cs)
    end

    test "allows valid statuses", %{project: project} do
      for status <- ~w(idle streaming tool_executing error) do
        cs =
          %Session{}
          |> Session.changeset(%{
            provider: "test",
            model: "test",
            project_id: project.id,
            status: status
          })

        assert cs.valid?, "Expected status #{status} to be valid"
      end
    end

    test "allows valid agents", %{project: project} do
      for agent <- ~w(build plan custom) do
        cs =
          %Session{}
          |> Session.changeset(%{
            provider: "test",
            model: "test",
            project_id: project.id,
            agent: agent
          })

        assert cs.valid?, "Expected agent #{agent} to be valid"
      end
    end

    test "sets defaults" do
      cs = %Session{} |> Session.changeset(%{provider: "p", model: "m", project_id: Ecto.UUID.generate()})
      assert get_field(cs, :status) == "idle"
      assert get_field(cs, :agent) == "build"
      assert get_field(cs, :config) == %{}
    end
  end

  describe "status_changeset/2" do
    test "updates status to valid value", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      cs = Session.status_changeset(session, "streaming")
      assert cs.valid?
    end

    test "rejects invalid status", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      cs = Session.status_changeset(session, "bad")
      refute cs.valid?
    end
  end

  describe "persistence" do
    test "inserts and retrieves session", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          project_id: project.id,
          title: "Test Session"
        })
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.title == "Test Session"
      assert found.provider == "anthropic"
    end

    test "preloads associations", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      loaded = Repo.preload(session, [:messages, :project])
      assert loaded.messages == []
      assert loaded.project.id == project.id
    end
  end
end
