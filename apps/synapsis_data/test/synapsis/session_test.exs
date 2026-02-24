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

  describe "default values" do
    test "status defaults to idle when not provided", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.status == "idle"
    end

    test "agent defaults to build when not provided", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.agent == "build"
    end

    test "config defaults to empty map when not provided", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.config == %{}
    end

    test "defaults survive round-trip through database", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.status == "idle"
      assert found.agent == "build"
      assert found.config == %{}
    end
  end

  describe "status_changeset/2 transitions" do
    test "transitions from idle to streaming", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      assert session.status == "idle"
      cs = Session.status_changeset(session, "streaming")
      assert cs.valid?
      {:ok, updated} = Repo.update(cs)
      assert updated.status == "streaming"
    end

    test "transitions from streaming to tool_executing", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, status: "streaming"})
        |> Repo.insert()

      cs = Session.status_changeset(session, "tool_executing")
      assert cs.valid?
      {:ok, updated} = Repo.update(cs)
      assert updated.status == "tool_executing"
    end

    test "transitions from tool_executing back to idle", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, status: "tool_executing"})
        |> Repo.insert()

      cs = Session.status_changeset(session, "idle")
      assert cs.valid?
      {:ok, updated} = Repo.update(cs)
      assert updated.status == "idle"
    end

    test "transitions to error from any state", %{project: project} do
      for initial_status <- ~w(idle streaming tool_executing) do
        {:ok, session} =
          %Session{}
          |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, status: initial_status})
          |> Repo.insert()

        cs = Session.status_changeset(session, "error")
        assert cs.valid?, "Expected transition from #{initial_status} to error to be valid"
        {:ok, updated} = Repo.update(cs)
        assert updated.status == "error"
      end
    end

    test "rejects transition to empty string", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      cs = Session.status_changeset(session, "")
      refute cs.valid?
    end

    test "nil status passes changeset validation but fails on DB not-null constraint", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id})
        |> Repo.insert()

      # validate_inclusion allows nil (only validates non-nil values),
      # so the changeset is valid but the DB would reject the nil
      cs = Session.status_changeset(session, nil)
      assert cs.valid?
      assert get_change(cs, :status) == nil
    end
  end

  describe "config field JSON storage" do
    test "stores and retrieves a simple JSON map", %{project: project} do
      config = %{"theme" => "dark", "font_size" => 14}

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, config: config})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.config == config
    end

    test "stores and retrieves nested JSON maps", %{project: project} do
      config = %{
        "provider_settings" => %{
          "temperature" => 0.7,
          "max_tokens" => 4096
        },
        "agent" => %{
          "system_prompt" => "You are helpful.",
          "tools" => ["bash", "file_read"]
        }
      }

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, config: config})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.config == config
      assert found.config["provider_settings"]["temperature"] == 0.7
      assert found.config["agent"]["tools"] == ["bash", "file_read"]
    end

    test "config can be updated after creation", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, config: %{"a" => 1}})
        |> Repo.insert()

      {:ok, updated} =
        session
        |> Session.changeset(%{config: %{"a" => 1, "b" => 2}})
        |> Repo.update()

      found = Repo.get!(Session, updated.id)
      assert found.config == %{"a" => 1, "b" => 2}
    end

    test "config can store empty nested structures", %{project: project} do
      config = %{"empty_map" => %{}, "empty_list" => []}

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{provider: "p", model: "m", project_id: project.id, config: config})
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.config["empty_map"] == %{}
      assert found.config["empty_list"] == []
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
