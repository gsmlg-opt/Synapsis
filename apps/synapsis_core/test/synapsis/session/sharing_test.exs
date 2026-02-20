defmodule Synapsis.Session.SharingTest do
  use Synapsis.DataCase
  alias Synapsis.{Session, Message, Project}
  alias Synapsis.Session.Sharing

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/sharing-test", slug: "sharing-test"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514",
        title: "Test Session"
      })
      |> Repo.insert()

    for i <- 1..3 do
      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
        parts: [%Synapsis.Part.Text{content: "Message #{i}"}],
        token_count: 10
      })
      |> Repo.insert!()
    end

    {:ok, session: session, project: project}
  end

  test "export/1 returns JSON with session and messages", %{session: session} do
    {:ok, json} = Sharing.export(session.id)
    data = Jason.decode!(json)

    assert data["version"] == "1.0"
    assert data["session"]["title"] == "Test Session"
    assert data["session"]["provider"] == "anthropic"
    assert length(data["messages"]) == 3
  end

  test "export round-trip preserves message content", %{session: session} do
    {:ok, json} = Sharing.export(session.id)
    data = Jason.decode!(json)

    messages = data["messages"]
    first = hd(messages)
    assert first["role"] == "user"
    assert hd(first["parts"])["content"] == "Message 1"
  end

  test "export/1 returns error for unknown session" do
    assert {:error, :not_found} = Sharing.export(Ecto.UUID.generate())
  end

  test "export_to_file/2 writes JSON to disk", %{session: session} do
    path = "/tmp/synapsis-sharing-test-#{System.unique_integer([:positive])}.json"
    assert :ok = Sharing.export_to_file(session.id, path)
    assert File.exists?(path)
    json = File.read!(path)
    data = Jason.decode!(json)
    assert data["version"] == "1.0"
    File.rm!(path)
  end

  test "export_to_file/2 returns error for unknown session" do
    assert {:error, :not_found} = Sharing.export_to_file(Ecto.UUID.generate(), "/tmp/nope.json")
  end

  test "import_session/2 creates session and messages from JSON", %{session: session} do
    {:ok, json} = Sharing.export(session.id)
    {:ok, imported} = Sharing.import_session(json, "/tmp/imported-project")

    assert imported.title =~ "[Imported]"
    assert imported.provider == "anthropic"
    assert imported.model == "claude-sonnet-4-20250514"

    messages =
      Synapsis.Message
      |> Ecto.Query.where([m], m.session_id == ^imported.id)
      |> Synapsis.Repo.all()

    assert length(messages) == 3
  end

  test "import_session/2 returns error for invalid JSON" do
    assert {:error, reason} = Sharing.import_session("not json", "/tmp/x")
    assert reason =~ "invalid JSON"
  end

  test "import_session/2 returns error for wrong JSON structure" do
    assert {:error, reason} = Sharing.import_session(Jason.encode!(%{foo: "bar"}), "/tmp/x")
    assert reason =~ "invalid session export format"
  end

  test "import_session/2 reuses existing project", %{session: session} do
    path = "/tmp/reuse-project-#{System.unique_integer([:positive])}"
    {:ok, json} = Sharing.export(session.id)

    # Import twice — should reuse project, not create duplicate
    {:ok, session1} = Sharing.import_session(json, path)
    {:ok, session2} = Sharing.import_session(json, path)

    assert session1.project_id == session2.project_id
  end

  test "export/1 serializes unknown part types as 'unknown'", %{session: session} do
    # Agent part has no export_part clause → falls back to %{type: "unknown"}
    %Message{}
    |> Message.changeset(%{
      session_id: session.id,
      role: "assistant",
      parts: [%Synapsis.Part.Agent{agent: "build", message: "Running..."}],
      token_count: 5
    })
    |> Repo.insert!()

    {:ok, json} = Sharing.export(session.id)
    data = Jason.decode!(json)
    last_msg = List.last(data["messages"])
    assert hd(last_msg["parts"])["type"] == "unknown"
  end

  test "import_session/2 maps unknown part types to Text fallback", %{session: _session} do
    json =
      Jason.encode!(%{
        "version" => "1.0",
        "session" => %{
          "title" => "Imported",
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-20250514",
          "agent" => "build",
          "config" => %{}
        },
        "messages" => [
          %{
            "role" => "user",
            "token_count" => 5,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "parts" => [%{"type" => "mystery_part", "foo" => "bar"}]
          }
        ]
      })

    {:ok, imported} = Sharing.import_session(json, "/tmp/sharing-fallback-#{System.unique_integer([:positive])}")
    msgs = Synapsis.Message |> Ecto.Query.where([m], m.session_id == ^imported.id) |> Synapsis.Repo.all()
    assert length(msgs) == 1
    assert hd(hd(msgs).parts) == %Synapsis.Part.Text{content: "[imported content]"}
  end
end
