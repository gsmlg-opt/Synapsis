defmodule Synapsis.Session.ForkTest do
  use Synapsis.DataCase
  alias Synapsis.{Session, Message, Project}
  alias Synapsis.Session.Fork

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/fork-test", slug: "fork-test"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514",
        title: "Original"
      })
      |> Repo.insert()

    msgs =
      for i <- 1..5 do
        {:ok, msg} =
          %Message{}
          |> Message.changeset(%{
            session_id: session.id,
            role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
            parts: [%Synapsis.Part.Text{content: "Message #{i}"}],
            token_count: 10
          })
          |> Repo.insert()

        msg
      end

    {:ok, session: session, project: project, messages: msgs}
  end

  test "fork/1 creates a full copy of the session", %{session: session} do
    {:ok, new_session} = Fork.fork(session.id)

    assert new_session.id != session.id
    assert new_session.title =~ "Fork of"
    assert new_session.provider == session.provider
    assert new_session.model == session.model

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Repo.all()

    assert length(new_messages) == 5
  end

  test "fork/1 returns error for unknown session" do
    assert {:error, :not_found} = Fork.fork(Ecto.UUID.generate())
  end

  test "fork/2 with at_message copies up to that message", %{session: session, messages: msgs} do
    target = Enum.at(msgs, 2)

    {:ok, new_session} = Fork.fork(session.id, at_message: target.id)

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Repo.all()

    assert length(new_messages) == 3
  end

  test "fork/2 with non-existent at_message creates full fork", %{session: session} do
    {:ok, new_session} = Fork.fork(session.id, at_message: Ecto.UUID.generate())

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Repo.all()

    # Non-existent message id: take_while returns all 5, find returns nil,
    # reject removes the nil -> all 5 messages are copied
    assert length(new_messages) == 5
  end

  test "fork preserves message roles", %{session: session} do
    {:ok, new_session} = Fork.fork(session.id)

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Ecto.Query.order_by([m], asc: m.inserted_at)
      |> Repo.all()

    roles = Enum.map(new_messages, & &1.role)
    assert roles == ["user", "assistant", "user", "assistant", "user"]
  end

  test "fork preserves message parts content", %{session: session} do
    {:ok, new_session} = Fork.fork(session.id)

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Ecto.Query.order_by([m], asc: m.inserted_at)
      |> Repo.all()

    first_parts = hd(new_messages).parts
    assert [%Synapsis.Part.Text{content: "Message 1"}] = first_parts
  end

  test "fork preserves provider and model", %{session: session} do
    {:ok, new_session} = Fork.fork(session.id)
    assert new_session.provider == "anthropic"
    assert new_session.model == "claude-sonnet-4-20250514"
  end

  test "fork at first message copies only 1 message", %{session: session, messages: msgs} do
    first = hd(msgs)
    {:ok, new_session} = Fork.fork(session.id, at_message: first.id)

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Repo.all()

    assert length(new_messages) == 1
  end

  test "fork at last message copies all messages", %{session: session, messages: msgs} do
    last = List.last(msgs)
    {:ok, new_session} = Fork.fork(session.id, at_message: last.id)

    new_messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^new_session.id)
      |> Repo.all()

    assert length(new_messages) == 5
  end
end
