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

    test "creates a session with project and preloads project association" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_preload_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "My Test Session"
        })

      assert session.id != nil
      assert session.project != nil
      assert session.project.id != nil
      assert session.title == "My Test Session"
    end

    test "defaults to anthropic when no config and no env vars set" do
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
      assert session.model == Synapsis.Providers.default_model("anthropic")
    end

    test "selects openai when OPENAI_API_KEY is set and ANTHROPIC not set" do
      prev_ant = System.get_env("ANTHROPIC_API_KEY")
      prev_oai = System.get_env("OPENAI_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("OPENAI_API_KEY", "sk-openai-test")

      on_exit(fn ->
        if prev_ant, do: System.put_env("ANTHROPIC_API_KEY", prev_ant)

        if prev_oai,
          do: System.put_env("OPENAI_API_KEY", prev_oai),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      {:ok, session} =
        Sessions.create("/tmp/test_sess_oai_env_#{:rand.uniform(100_000)}")

      assert session.provider == "openai"
      assert session.model == Synapsis.Providers.default_model("openai")
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

    test "uses custom agent when provided" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_agent_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "plan"
        })

      assert session.agent == "plan"
    end
  end

  describe "get/1" do
    test "returns session with project and messages preloaded" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_get", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, found} = Sessions.get(session.id)
      assert found.id == session.id
      assert is_list(found.messages)
      assert found.project != nil
      assert found.project.path == "/tmp/test_sessions_get"
    end

    test "returns error for missing session" do
      assert {:error, :not_found} = Sessions.get(Ecto.UUID.generate())
    end

    test "raises for nil session id" do
      assert_raise ArgumentError, fn ->
        Sessions.get(nil)
      end
    end
  end

  describe "list/2" do
    test "lists sessions for a project path" do
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

    test "returns empty list for unknown project path" do
      {:ok, sessions} = Sessions.list("/tmp/nonexistent_project_path_#{:rand.uniform(100_000)}")
      assert sessions == []
    end

    test "respects the limit option" do
      path = "/tmp/test_sessions_list_limit_#{:rand.uniform(100_000)}"

      for _ <- 1..5 do
        Sessions.create(path, %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
      end

      {:ok, sessions} = Sessions.list(path, limit: 3)
      assert length(sessions) == 3
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

    test "returns messages ordered by inserted_at ascending" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_msgs_order_#{:rand.uniform(100_000)}", %{
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

      messages = Sessions.get_messages(session.id)
      assert length(messages) == 3

      contents =
        Enum.map(messages, fn m ->
          [%Synapsis.Part.Text{content: c}] = m.parts
          c
        end)

      assert contents == ["Message 1", "Message 2", "Message 3"]
    end

    test "returns empty list for unknown session_id" do
      assert [] = Sessions.get_messages(Ecto.UUID.generate())
    end
  end

  describe "delete/1" do
    test "deletes a session and returns ok tuple" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_del", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert {:ok, _} = Sessions.delete(session.id)
      assert {:error, :not_found} = Sessions.get(session.id)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Sessions.delete(Ecto.UUID.generate())
    end
  end

  describe "send_message/2" do
    test "delegates binary content to worker" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_send_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      result = Sessions.send_message(session.id, "Hello world")
      assert result == :ok
    end

    test "delegates map with content key to worker" do
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

      result =
        Sessions.send_message(session.id, %{
          content: "Check this image",
          images: ["/nonexistent/image.jpg"]
        })

      assert result == :ok
    end

    test "ensure_running/1 is a no-op when worker is already running" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_ensure_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      # Worker is already started by create/2, ensure_running should be a no-op
      assert :ok = Sessions.ensure_running(session.id)
    end
  end

  describe "cancel/1" do
    test "cancel broadcasts to session worker (cast - always ok)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_cancel_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

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
      # claude-sonnet limit 200k * 80% = 160k threshold
      # 15 * 12k = 180k > 160k -> compaction triggered
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
