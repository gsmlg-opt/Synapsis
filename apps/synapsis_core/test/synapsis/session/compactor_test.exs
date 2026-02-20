defmodule Synapsis.Session.CompactorTest do
  use Synapsis.DataCase
  alias Synapsis.{Session, Message, Project}
  alias Synapsis.Session.Compactor

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/compact-test", slug: "compact-test"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session, project: project}
  end

  test "compact/2 compacts old messages into a summary", %{session: session} do
    # Insert 15 messages
    for i <- 1..15 do
      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
        parts: [%Synapsis.Part.Text{content: "Message #{i} content with enough text to count"}],
        token_count: 1000
      })
      |> Repo.insert!()
    end

    messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^session.id)
      |> Ecto.Query.order_by([m], asc: m.inserted_at)
      |> Repo.all()

    assert length(messages) == 15

    result = Compactor.compact(session.id, messages)
    assert result == :compacted

    remaining =
      Message
      |> Ecto.Query.where([m], m.session_id == ^session.id)
      |> Repo.all()

    # Should have 10 kept + 1 summary = 11
    assert length(remaining) == 11
  end

  test "compact/2 does nothing when few messages", %{session: session} do
    for i <- 1..5 do
      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: "user",
        parts: [%Synapsis.Part.Text{content: "Message #{i}"}],
        token_count: 100
      })
      |> Repo.insert!()
    end

    messages =
      Message
      |> Ecto.Query.where([m], m.session_id == ^session.id)
      |> Ecto.Query.order_by([m], asc: m.inserted_at)
      |> Repo.all()

    assert Compactor.compact(session.id, messages) == :ok
  end

  test "maybe_compact/3 triggers compaction when extra_tokens push over threshold", %{
    session: session
  } do
    # Insert 15 messages with 10k tokens each = 150k total
    # Model limit for claude-sonnet is 200k, threshold 80% = 160k
    # 150k alone is under threshold
    for i <- 1..15 do
      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
        parts: [%Synapsis.Part.Text{content: "Message #{i}"}],
        token_count: 10_000
      })
      |> Repo.insert!()
    end

    # Without extra_tokens: 150k < 160k threshold → no compaction
    assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :ok

    # With 20k extra_tokens (failure log): 170k > 160k threshold → compaction
    assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514",
             extra_tokens: 20_000
           ) == :compacted
  end
end
