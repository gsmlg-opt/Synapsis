defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase

  alias Synapsis.{Sessions, Message, Repo}

  describe "create/2" do
    test "creates a session for a new project" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_create", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert session.id
      assert session.status == "idle"
      assert session.agent == "build"
      assert session.project.path == "/tmp/test_sessions_create"
    end

    test "reuses existing project" do
      {:ok, s1} =
        Sessions.create("/tmp/test_sessions_reuse", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, s2} =
        Sessions.create("/tmp/test_sessions_reuse", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert s1.project_id == s2.project_id
      assert s1.id != s2.id
    end
  end

  describe "get/1" do
    test "returns session with messages" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_get", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, found} = Sessions.get(session.id)
      assert found.id == session.id
      assert is_list(found.messages)
    end

    test "returns error for missing session" do
      assert {:error, :not_found} = Sessions.get(Ecto.UUID.generate())
    end
  end

  describe "list/2" do
    test "lists sessions for a project" do
      {:ok, _} =
        Sessions.create("/tmp/test_sessions_list", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, _} =
        Sessions.create("/tmp/test_sessions_list", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, sessions} = Sessions.list("/tmp/test_sessions_list")
      assert length(sessions) >= 2
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_del", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert {:ok, _} = Sessions.delete(session.id)
      assert {:error, :not_found} = Sessions.get(session.id)
    end
  end

  describe "fork/2" do
    test "forks a session copying all messages" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_fork", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

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

      {:ok, forked} = Sessions.fork(session.id)

      assert forked.id != session.id
      assert forked.provider == session.provider
      assert forked.model == session.model
      assert forked.title =~ "Fork"
      assert length(Sessions.get_messages(forked.id)) == 3
    end
  end

  describe "compact/1" do
    test "returns :ok when tokens are below threshold" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_compact_ok", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

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

      assert Sessions.compact(session.id) == :ok
    end

    test "returns :compacted when tokens exceed 80% of model limit" do
      # claude-sonnet limit 200k × 80% = 160k threshold
      # 15 × 12k = 180k > 160k → compaction triggered
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_compact_trigger", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      for i <- 1..15 do
        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
          parts: [%Synapsis.Part.Text{content: "Message #{i}"}],
          token_count: 12_000
        })
        |> Repo.insert!()
      end

      assert Sessions.compact(session.id) == :compacted
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Sessions.compact(Ecto.UUID.generate())
    end
  end
end
