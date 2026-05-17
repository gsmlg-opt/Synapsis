defmodule SynapsisWeb.ChatLiveTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{AgentConfigs, Sessions}

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

    test "keeps the conversation agent stable on the session route", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "reviewer"})

      {:ok, view, html} = live(conn, ~p"/chat/#{session.id}")

      assert html =~ "Reviewer"
      refute has_element?(view, "select[name='model']")
      refute has_element?(view, "[phx-click='switch_mode']")
    end
  end
end
