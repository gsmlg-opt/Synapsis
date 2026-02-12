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
end
