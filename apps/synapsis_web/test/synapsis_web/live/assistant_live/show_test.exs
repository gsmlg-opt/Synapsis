defmodule SynapsisWeb.AssistantLive.ShowTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Sessions

  describe "assistant show page" do
    test "renders empty state when no session selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/assistant/build/sessions")
      assert html =~ "Build Assistant"
    end

    test "renders personality indicator with primary/70 style in session header", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, _view, html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")
      # Personality name appears in the styled span (text-primary/70 class)
      assert html =~ "text-primary/70"
      assert html =~ "Build"
      # Provider/model info in subtext
      assert html =~ "anthropic/test"
    end

    test "handles session_compacted PubSub event and reloads messages", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session.id}",
        {:session_compacted, session.id, %{messages_removed: 5, messages_kept: 10}}
      )

      # View should not crash and messages assign should be refreshed
      html = render(view)
      assert html =~ "text-primary/70"
    end

    test "handles session_compacted when no session is selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions")

      # Directly send to the view process — current_session is nil so messages stays []
      send(
        view.pid,
        {:session_compacted, "nonexistent-id", %{messages_removed: 3, messages_kept: 7}}
      )

      # View should not crash
      assert render(view) =~ "Build Assistant"
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

    test "handles system_message with non-compaction type without crash", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, view, _html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")

      # Non-compaction system messages fall through to the catch-all handle_info/2
      send(view.pid, {:system_message, %{type: :info, text: "Some info message", metadata: %{}}})

      # View should not crash
      assert render(view) =~ "anthropic/test"
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

  describe "chat_bubble component label rendering" do
    test "label renders only for assistant role via integration", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "build"})

      {:ok, _view, html} = live(conn, ~p"/assistant/build/sessions/#{session.id}")
      # The personality indicator span in the session header uses text-primary/70
      assert html =~ "text-primary/70"
    end

    test "chat_bubble label attr defaults to nil — no label div without explicit label", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "assistant"}
        )

      # Without a label, the conditional :if={@label && @role == "assistant"} is false
      refute html =~ "text-xs font-medium text-primary/70"
    end

    test "chat_bubble label renders for assistant role", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "assistant", label: "My Assistant"}
        )

      assert html =~ "My Assistant"
      assert html =~ "text-primary/70"
    end

    test "chat_bubble label does not render for user role", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "user", label: "My Assistant"}
        )

      refute html =~ "text-primary/70"
      refute html =~ "My Assistant"
    end

    test "chat_bubble label does not render for system role", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "system", label: "My Assistant"}
        )

      refute html =~ "text-primary/70"
      refute html =~ "My Assistant"
    end
  end
end
