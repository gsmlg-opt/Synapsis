defmodule Synapsis.SchemaTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Session, Message}

  describe "Project" do
    test "valid changeset" do
      changeset = Project.changeset(%Project{}, %{path: "/tmp/myproject", slug: "myproject"})
      assert changeset.valid?
    end

    test "requires path and slug" do
      changeset = Project.changeset(%Project{}, %{})
      refute changeset.valid?
      assert %{path: ["can't be blank"], slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "inserts and queries" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/test_project", slug: "test-project"})
        |> Repo.insert()

      assert project.id
      assert project.path == "/tmp/test_project"
      found = Repo.get!(Project, project.id)
      assert found.path == "/tmp/test_project"
    end

    test "slug_from_path" do
      assert Project.slug_from_path("/home/user/My Project") == "my-project"
      assert Project.slug_from_path("/tmp/simple") == "simple"
    end
  end

  describe "Session" do
    setup do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/sess_test", slug: "sess-test"})
        |> Repo.insert()

      %{project: project}
    end

    test "valid changeset", %{project: project} do
      changeset =
        Session.changeset(%Session{}, %{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert changeset.valid?
    end

    test "requires provider and model" do
      changeset = Session.changeset(%Session{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:provider]
      assert errors[:model]
    end

    test "inserts with defaults", %{project: project} do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      assert session.status == "idle"
      assert session.agent == "build"
    end
  end

  describe "Message" do
    setup do
      {:ok, project} =
        %Project{}
        |> Project.changeset(%{path: "/tmp/msg_test", slug: "msg-test"})
        |> Repo.insert()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      %{session: session}
    end

    test "inserts message with parts", %{session: session} do
      parts = [
        %Synapsis.Part.Text{content: "Hello!"},
        %Synapsis.Part.ToolUse{
          tool: "file_read",
          tool_use_id: "toolu_001",
          input: %{"path" => "/tmp/test.txt"},
          status: :pending
        }
      ]

      {:ok, message} =
        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          role: "assistant",
          parts: parts,
          token_count: 15
        })
        |> Repo.insert()

      assert message.id
      assert length(message.parts) == 2

      # Reload and check round-trip
      loaded = Repo.get!(Message, message.id)

      assert [%Synapsis.Part.Text{content: "Hello!"}, %Synapsis.Part.ToolUse{tool: "file_read"}] =
               loaded.parts
    end

    test "validates role", %{session: session} do
      changeset =
        Message.changeset(%Message{}, %{
          session_id: session.id,
          role: "invalid"
        })

      refute changeset.valid?
    end
  end
end
