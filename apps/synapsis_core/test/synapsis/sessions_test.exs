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

    test "defaults to anthropic when no config and no env vars set" do
      # Temporarily clear env vars that would influence provider selection
      prev_ant = System.get_env("ANTHROPIC_API_KEY")
      prev_oai = System.get_env("OPENAI_API_KEY")
      prev_goo = System.get_env("GOOGLE_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      on_exit(fn ->
        if prev_ant, do: System.put_env("ANTHROPIC_API_KEY", prev_ant)
        if prev_oai, do: System.put_env("OPENAI_API_KEY", prev_oai)
        if prev_goo, do: System.put_env("GOOGLE_API_KEY", prev_goo)
      end)

      {:ok, session} =
        Sessions.create("/tmp/test_sess_default_#{:rand.uniform(100_000)}")

      assert session.provider == "anthropic"
      assert session.model == "claude-sonnet-4-20250514"
    end

    test "selects openai when OPENAI_API_KEY is set and ANTHROPIC not set" do
      prev_ant = System.get_env("ANTHROPIC_API_KEY")
      prev_oai = System.get_env("OPENAI_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("OPENAI_API_KEY", "sk-openai-test")

      on_exit(fn ->
        if prev_ant, do: System.put_env("ANTHROPIC_API_KEY", prev_ant)
        if prev_oai, do: System.put_env("OPENAI_API_KEY", prev_oai), else: System.delete_env("OPENAI_API_KEY")
      end)

      {:ok, session} =
        Sessions.create("/tmp/test_sess_oai_env_#{:rand.uniform(100_000)}")

      assert session.provider == "openai"
      assert session.model == "gpt-4o"
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

  describe "list_by_project/2" do
    test "returns sessions for a project" do
      {:ok, s1} =
        Sessions.create("/tmp/test_sessions_by_proj", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      sessions = Sessions.list_by_project(s1.project_id)
      ids = Enum.map(sessions, & &1.id)
      assert s1.id in ids
    end

    test "returns empty list for unknown project_id" do
      sessions = Sessions.list_by_project(Ecto.UUID.generate())
      assert sessions == []
    end
  end

  describe "recent/1" do
    test "returns recently updated sessions" do
      {:ok, _} =
        Sessions.create("/tmp/test_sessions_recent", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      recents = Sessions.recent()
      assert is_list(recents)
      assert length(recents) >= 1
    end
  end

  describe "get_messages/1" do
    test "returns empty list for session with no messages" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_msgs", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert [] = Sessions.get_messages(session.id)
    end

    test "returns empty list for unknown session_id" do
      assert [] = Sessions.get_messages(Ecto.UUID.generate())
    end
  end

  describe "export/1" do
    test "returns JSON string with session data" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_export", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, json} = Sessions.export(session.id)
      data = Jason.decode!(json)
      assert data["version"] == "1.0"
      assert is_map(data["session"])
      assert is_list(data["messages"])
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Sessions.export(Ecto.UUID.generate())
    end
  end

  describe "export_to_file/2" do
    test "writes JSON to a file" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_export_file", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      path = "/tmp/synapsis-sessions-test-#{System.unique_integer([:positive])}.json"
      assert :ok = Sessions.export_to_file(session.id, path)
      assert File.exists?(path)
      data = Jason.decode!(File.read!(path))
      assert data["version"] == "1.0"
      File.rm!(path)
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Sessions.export_to_file(Ecto.UUID.generate(), "/tmp/x.json")
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

  describe "send_message/2 (map form)" do
    test "sends message via map with content key" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_map_msg_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      result = Sessions.send_message(session.id, %{content: "Hello via map"})
      assert result == :ok
    end

    test "sends message with images list (filters invalid paths)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_img_msg_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      # Invalid image paths are filtered out - should still succeed
      result =
        Sessions.send_message(session.id, %{
          content: "Check this image",
          images: ["/nonexistent/image.jpg"]
        })

      assert result == :ok
    end
  end

  describe "cancel/1" do
    test "cancel broadcasts to session worker (cast - always ok)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_cancel_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      # Ensure session is running so cancel has a target
      # cancel is a GenServer.cast so always returns :ok even if process doesn't receive it
      assert :ok = Sessions.cancel(session.id)
    end
  end

  describe "switch_agent/2" do
    test "switches agent mode for a running session" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_switch_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "build"
        })

      result = Sessions.switch_agent(session.id, "plan")
      assert result == :ok

      {:ok, updated} = Sessions.get(session.id)
      assert updated.agent == "plan"
    end
  end
end
