defmodule SynapsisWeb.AssistantLive.ShowTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.Sessions

  describe "assistant show page" do
    test "renders empty state when no session selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/assistant/build/sessions")
      assert html =~ "Build Assistant"
    end

    test "renders personality indicator in session header", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, _view, html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")
      # Personality name appears in header
      assert html =~ "Build"
      # Provider/model info in subtext
      assert html =~ "anthropic/test"
    end

    test "handles session_compacted PubSub event without crash", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session.id}",
        {:session_compacted, session.id, %{messages_removed: 5, messages_kept: 10}}
      )

      # View should not crash
      assert render(view) =~ "Build"
    end

    test "handles system_message compaction notification", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session.id}",
        {:system_message,
         %{
           type: :compaction,
           text: "Context compacted: 5 messages summarized, 10 recent messages preserved",
           metadata: %{}
         }}
      )

      html = render(view)
      assert html =~ "Context compacted"
    end

    test "receives heartbeat notification via PubSub", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "heartbeat:notifications",
        {:heartbeat_completed, "config-123",
         %{name: "morning-briefing", executed_at: DateTime.utc_now(), result: "Test result"}}
      )

      html = render(view)
      assert html =~ "morning-briefing"
      assert html =~ "Test result"
    end
  end
end
