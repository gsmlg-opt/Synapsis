defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase

  alias Synapsis.{AgentConfigs, Message, ProviderConfig, Repo, SessionPermission, Sessions}

  @provider_env_vars ~w(
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
    ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
    ANTHROPIC_FAST_MODEL ANTHROPIC_EXPERT_MODEL OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL
    OPENAI_DEFAULT_MODEL GOOGLE_API_KEY GOOGLE_BASE_URL GOOGLE_MODEL GOOGLE_DEFAULT_MODEL
    OPENROUTER_API_KEY OPENROUTER_BASE_URL OPENROUTER_MODEL CHATGPT_OAUTH_TOKEN
    CHATGPT_BASE_URL CHATGPT_MODEL
  )

  defmodule TerminalNode do
    @behaviour Synapsis.Agent.Runtime.Node

    @impl true
    def run(state, _ctx), do: {:end, state}
  end

  setup do
    Repo.delete_all(ProviderConfig)
    :ok
  end

  describe "create/2" do
    test "creates a session for a new project" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_create", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert session.id
      assert session.status == "idle"
      assert session.agent == "main"
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

    test "applies selected agent permission mode to the session" do
      agent_name = "restricted-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        AgentConfigs.create(%{
          name: agent_name,
          permission_mode: "restrict"
        })

      {:ok, session} =
        Sessions.create("/tmp/test_sessions_permission_#{System.unique_integer([:positive])}", %{
          provider: "anthropic",
          model: "test-model",
          agent: agent_name
        })

      permission = Repo.get_by!(SessionPermission, session_id: session.id)

      assert permission.mode == :interactive
      assert permission.allow_read == :ask
      assert permission.allow_write == :ask
      assert permission.allow_execute == :ask
      assert permission.allow_destructive == :ask
      assert permission.tool_overrides == %{}
    end

    test "defaults to anthropic when no config and no env vars set" do
      preserve_provider_env()
      Enum.each(@provider_env_vars, &System.delete_env/1)

      {:ok, session} =
        Sessions.create(temp_project_without_agent_default("test_sess_default"))

      assert session.provider == "anthropic"
      assert session.model == Synapsis.Providers.default_model("anthropic")
    end

    test "selects openai when OPENAI_API_KEY is set and ANTHROPIC not set" do
      preserve_provider_env()
      Enum.each(@provider_env_vars, &System.delete_env/1)
      System.put_env("OPENAI_API_KEY", "sk-openai-test")

      {:ok, session} =
        Sessions.create(temp_project_without_agent_default("test_sess_oai_env"))

      assert session.provider == "openai"
      assert session.model == Synapsis.Providers.default_model("openai")
    end

    test "uses Anthropic-compatible auth token and model env aliases" do
      preserve_provider_env()
      Enum.each(@provider_env_vars, &System.delete_env/1)
      System.put_env("ANTHROPIC_AUTH_TOKEN", "auth-token-test")
      System.put_env("ANTHROPIC_MODEL", "env-anthropic-model")

      {:ok, session} =
        Sessions.create(temp_project_without_agent_default("test_sess_ant_alias_env"))

      assert session.provider == "anthropic"
      assert session.model == "env-anthropic-model"
    end

    test "uses project default agent provider and model when omitted" do
      dir = Path.join(System.tmp_dir!(), "test_sess_project_default_#{System.unique_integer()}")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".opencode.json"),
        Jason.encode!(%{
          "agents" => %{
            "default" => %{
              "provider" => "zhipu-coding",
              "model" => "glm-4.7"
            }
          }
        })
      )

      {:ok, session} = Sessions.create(dir)

      assert session.provider == "zhipu-coding"
      assert session.model == "glm-4.7"
    end

    test "uses first enabled model from configured providers when no config or env default exists" do
      preserve_provider_env()
      Enum.each(@provider_env_vars, &System.delete_env/1)

      Repo.delete_all(ProviderConfig)

      Repo.insert!(%ProviderConfig{
        name: "zhipu-coding",
        type: "anthropic",
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_key_encrypted: "sk-test",
        config: %{"enabled_models" => ["glm-4.7", "glm-5"]},
        enabled: true
      })

      {:ok, session} =
        Sessions.create(temp_project_without_agent_default("test_sess_configured_provider"))

      assert session.provider == "zhipu-coding"
      assert session.model == "glm-4.7"
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

  defp preserve_provider_env do
    previous = Map.new(@provider_env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)
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
          provider: "unknown-test-provider",
          model: "test-model"
        })

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      result = Sessions.send_message(session.id, "Hello world")
      assert result == :ok
      assert_terminal_status(session.id, "error")
    end

    test "delegates map with content key to worker" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_map_msg_#{:rand.uniform(100_000)}", %{
          provider: "unknown-test-provider",
          model: "test-model"
        })

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      result = Sessions.send_message(session.id, %{content: "Hello via map"})
      assert result == :ok
      assert_terminal_status(session.id, "error")
    end

    test "sends message with images list (filters invalid paths)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_img_msg_#{:rand.uniform(100_000)}", %{
          provider: "unknown-test-provider",
          model: "test-model"
        })

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      result =
        Sessions.send_message(session.id, %{
          content: "Check this image",
          images: ["/nonexistent/image.jpg"]
        })

      assert result == :ok
      assert_terminal_status(session.id, "error")
    end

    test "accepts another message after a graph turn completes" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_multi_turn_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
      [{worker_pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

      assert :ok = Sessions.send_message(session.id, "first")

      complete_graph_turn(worker_pid)
      assert_receive {"session_status", %{status: "idle"}}, 1_000

      assert :ok = Sessions.send_message(session.id, "second")
      Synapsis.Session.DynamicSupervisor.stop_session(session.id)
    end

    test "restarts a terminal graph runner before sending" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_terminal_runner_#{:rand.uniform(100_000)}", %{
          provider: "unknown-test-provider",
          model: "test-model"
        })

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      [{worker_pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
      replace_runner_with_terminal_runner(worker_pid, session.id)

      assert :ok = Sessions.send_message(session.id, "after terminal runner")
      assert_terminal_status(session.id, "error")
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

  defp replace_runner_with_terminal_runner(worker_pid, run_id) do
    old_runner_pid = :sys.get_state(worker_pid).runner_pid
    if Process.alive?(old_runner_pid), do: GenServer.stop(old_runner_pid, :normal, 5_000)

    {:ok, runner_pid} =
      Synapsis.Agent.Runtime.Runner.start_link(
        graph: %{
          nodes: %{done: __MODULE__.TerminalNode},
          edges: %{done: :end},
          start: :done
        },
        state: %{},
        run_id: run_id
      )

    assert %{status: :completed} = Synapsis.Agent.Runtime.Runner.await(runner_pid)

    :sys.replace_state(worker_pid, fn state ->
      %{state | runner_pid: runner_pid}
    end)
  end

  defp complete_graph_turn(worker_pid) do
    receive do
      {"done", %{}} ->
        :ok
    after
      100 ->
        assert runner_waiting_on?(worker_pid, :llm_stream)
        send(worker_pid, :provider_done)
        assert_receive {"done", %{}}, 1_000
    end
  end

  defp assert_terminal_status(session_id, expected_status) do
    try do
      assert_receive {"session_status", %{status: ^expected_status}}, 5_000
    after
      Synapsis.Session.DynamicSupervisor.stop_session(session_id)
    end
  end

  defp runner_waiting_on?(worker_pid, node, attempts \\ 20)
  defp runner_waiting_on?(_worker_pid, _node, 0), do: false

  defp runner_waiting_on?(worker_pid, node, attempts) do
    runner_pid = :sys.get_state(worker_pid).runner_pid

    case Synapsis.Agent.Runtime.Runner.snapshot(runner_pid) do
      %{status: :waiting, node: ^node} ->
        true

      _snapshot ->
        Process.sleep(25)
        runner_waiting_on?(worker_pid, node, attempts - 1)
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

  describe "retry/1" do
    test "returns error when no messages exist in session" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_retry_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert {:error, :no_messages} = Sessions.retry(session.id)
    end
  end

  describe "approve_tool/2" do
    test "delegates approve_tool to session worker (cast - no return value)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_approve_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      # approve_tool is a cast — it returns :ok without error
      Sessions.approve_tool(session.id, "tu_fake_id")
      # No crash means it delegates correctly
      assert true
    end
  end

  describe "deny_tool/2" do
    test "delegates deny_tool to session worker (cast - no return value)" do
      {:ok, session} =
        Sessions.create("/tmp/test_sess_deny_#{:rand.uniform(100_000)}", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      # deny_tool is a cast — it returns :ok without error
      Sessions.deny_tool(session.id, "tu_fake_id")
      assert true
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

      assert Sessions.compact(session.id) == {:ok, :no_compaction_needed}
    end

    test "returns structured result when tokens exceed 80% of model limit" do
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

      assert {:ok, %{removed: _, kept: _}} = Sessions.compact(session.id)
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Sessions.compact(Ecto.UUID.generate())
    end
  end

  defp temp_project_without_agent_default(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".opencode.json"),
      Jason.encode!(%{
        "providers" => nil,
        "agents" => %{
          "default" => %{
            "provider" => nil,
            "model" => nil
          }
        }
      })
    )

    dir
  end
end
