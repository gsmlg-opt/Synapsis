defmodule SynapsisWeb.ChatLiveTest do
  use SynapsisWeb.ConnCase

  import Ecto.Query

  alias Synapsis.{AgentConfigs, ProviderConfig, Repo, Session, Sessions}

  setup do
    Synapsis.Repo.delete_all(Synapsis.AgentConfig)

    {:ok, _main} =
      AgentConfigs.create(%{
        name: "main",
        label: "Main",
        provider: "anthropic",
        model: "test-model"
      })

    {:ok, _reviewer} =
      AgentConfigs.create(%{
        name: "reviewer",
        label: "Reviewer",
        provider: "anthropic",
        model: "review-model"
      })

    :ok
  end

  describe "chat page" do
    test "renders global chat with agent selector and no model selector", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/chat")

      assert html =~ "New Chat"
      assert has_element?(view, "select[name='agent']")
      refute has_element?(view, "select[name='model']")
    end

    test "creates a global conversation for the selected agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("form[phx-submit='create_session']", %{"agent" => "reviewer"})
      |> render_submit()

      [session] = Sessions.recent(limit: 1)
      assert session.agent == "reviewer"
      assert session.project.path == "__global__"
      assert_patch(view, ~p"/chat/#{session.id}")
    end

    test "creates chat with configured provider when selected agent has no model", %{conn: conn} do
      Repo.delete_all(Session)
      Repo.delete_all(Synapsis.AgentConfig)
      Repo.delete_all(ProviderConfig)

      {:ok, _main} =
        AgentConfigs.create(%{
          name: "main",
          label: "Main"
        })

      Repo.insert!(%ProviderConfig{
        name: "zhipu-coding",
        type: "anthropic",
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_key_encrypted: "sk-test",
        config: %{"enabled_models" => ["glm-4.7", "glm-5"]},
        enabled: true
      })

      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> form("form[phx-submit='create_session']", %{"agent" => "main"})
      |> render_submit()

      [session] = Sessions.recent(limit: 1)
      assert session.provider == "zhipu-coding"
      assert session.model == "glm-4.7"
    end

    test "keeps the conversation agent stable on the session route", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "reviewer"})

      {:ok, view, html} = live(conn, ~p"/chat/#{session.id}")

      assert html =~ "Reviewer"
      refute has_element?(view, "select[name='model']")
      refute has_element?(view, "[phx-click='switch_mode']")
    end

    test "renders sent user message immediately", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "reviewer"})

      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      html = render_hook(view, "send_message", %{"content" => "show me immediately"})

      assert html =~ "show me immediately"
    end

    test "recovers a stale streaming session when opening chat route", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "reviewer"})

      Synapsis.Session.DynamicSupervisor.stop_session(session.id)

      session
      |> Session.status_changeset("streaming")
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      refute has_element?(view, "el-dm-markdown-input#message-input[disabled]")
      assert Repo.get!(Session, session.id).status == "idle"
    end

    test "recovers an old transient status when the worker is already running", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "reviewer"})

      assert [_worker] = Registry.lookup(Synapsis.Session.Registry, session.id)

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      from(s in Session, where: s.id == ^session.id)
      |> Repo.update_all(set: [status: "streaming", updated_at: stale_at])

      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      refute has_element?(view, "el-dm-markdown-input#message-input[disabled]")
      assert Repo.get!(Session, session.id).status == "idle"
    end

    test "recovers unsupported provider and model for an old stale chat", %{conn: conn} do
      Repo.delete_all(Synapsis.AgentConfig)
      Repo.delete_all(ProviderConfig)

      {:ok, _main} =
        AgentConfigs.create(%{
          name: "main",
          label: "Main"
        })

      Repo.insert!(%ProviderConfig{
        name: "zhipu-coding",
        type: "anthropic",
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_key_encrypted: "sk-test",
        config: %{"enabled_models" => ["glm-4.7", "glm-5"]},
        enabled: true
      })

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: "anthropic",
          model: "claude-sonnet-4-6",
          agent: "main"
        })

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      session
      |> Session.changeset(%{
        status: "streaming",
        config: %{
          "agents" => %{
            "default" => %{
              "provider" => "zhipu-coding",
              "model" => "glm-4.7"
            }
          }
        }
      })
      |> Repo.update!()

      from(s in Session, where: s.id == ^session.id)
      |> Repo.update_all(set: [updated_at: stale_at])

      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      recovered = Repo.get!(Session, session.id)
      refute has_element?(view, "el-dm-markdown-input#message-input[disabled]")
      assert recovered.status == "idle"
      assert recovered.provider == "zhipu-coding"
      assert recovered.model == "glm-4.7"
    end

    test "recovers unsupported provider and model for an idle chat", %{conn: conn} do
      Repo.delete_all(Synapsis.AgentConfig)
      Repo.delete_all(ProviderConfig)

      {:ok, _main} = AgentConfigs.create(%{name: "main", label: "Main"})

      Repo.insert!(%ProviderConfig{
        name: "zhipu-coding",
        type: "anthropic",
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_key_encrypted: "sk-test",
        config: %{"enabled_models" => ["glm-4.7", "glm-5"]},
        enabled: true
      })

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: "anthropic",
          model: "claude-sonnet-4-6",
          agent: "main"
        })

      session
      |> Session.changeset(%{
        config: %{
          "agents" => %{
            "default" => %{
              "provider" => "zhipu-coding",
              "model" => "glm-4.7"
            }
          }
        }
      })
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")

      recovered = Repo.get!(Session, session.id)
      refute has_element?(view, "el-dm-markdown-input#message-input[disabled]")
      assert recovered.status == "idle"
      assert recovered.provider == "zhipu-coding"
      assert recovered.model == "glm-4.7"
    end
  end
end
