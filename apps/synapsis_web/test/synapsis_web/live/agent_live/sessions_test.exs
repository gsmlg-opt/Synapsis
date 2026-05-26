defmodule SynapsisWeb.AgentLive.SessionsTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Sessions

  describe "agent sessions page" do
    test "renders empty state when no session selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agent/agents/main/sessions")
      assert html =~ "Main Agent"
    end

    test "renders a structured session sidebar with active session rows", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(view, "aside[data-agent-session-sidebar]", "Main Agent")
      assert has_element?(view, "nav[aria-label='Agent sessions']")
      assert has_element?(view, "div[data-session-row='#{session.id}'][aria-current='page']")
      assert html =~ "Sessions"
      assert html =~ "New Session"
      assert html =~ "anthropic/test"
    end

    test "renders personality indicator with primary/70 style in session header", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, _view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      # Personality name appears in the styled span (text-primary/70 class)
      assert html =~ "text-primary/70"
      assert html =~ "Main"
      # Provider/model info in subtext
      assert html =~ "anthropic/test"
    end

    test "handles session_compacted PubSub event and reloads messages", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

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
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions")

      # Directly send to the view process — current_session is nil so messages stays []
      send(
        view.pid,
        {:session_compacted, "nonexistent-id", %{messages_removed: 3, messages_kept: 7}}
      )

      # View should not crash
      assert render(view) =~ "Main Agent"
    end

    test "handles system_message compaction notification", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

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
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      # Non-compaction system messages fall through to the catch-all handle_info/2
      send(view.pid, {:system_message, %{type: :info, text: "Some info message", metadata: %{}}})

      # View should not crash
      assert render(view) =~ "anthropic/test"
    end

    test "receives heartbeat notification via PubSub", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

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

    test "ignores stale active status after a completed turn", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(view.pid, {"done", %{}})
      render(view)

      send(view.pid, {"session_status", %{status: "streaming"}})
      html = render(view)

      refute html =~ "Generating..."
      refute has_element?(view, "el-dm-chat-input#message-input[disabled]")
      assert Synapsis.Repo.get!(Synapsis.Session, session.id).status == "idle"
    end

    test "chat input uses DuskMoon chat input send event", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(view, "el-dm-chat-input#message-input[phx-hook='WebComponentHook']")

      render_hook(view, "send_message", %{"value" => "   "})

      assert Sessions.get_messages(session.id) == []
    end
  end

  describe "chat_bubble component DuskMoon rendering" do
    test "chat_bubble renders a phoenix_duskmoon chat element for user messages", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "user"}
        )

      assert html =~ "<el-dm-chat"
      assert html =~ ~s(align="end")
      assert html =~ ~s(color="primary")
      assert html =~ ~s(variant="filled")
    end

    test "chat_bubble renders avatar and message metadata", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble
              role={assigns.role}
              label={assigns.label}
              avatar={assigns.avatar}
              time={assigns.time}
              status={assigns.status}
            >
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "assistant", label: "Pi", avatar: "π", time: "16:29:00", status: "out: 99"}
        )

      assert html =~ ~s(author="Pi")
      assert html =~ ~s(avatar="π")
      assert html =~ ~s(time="16:29:00")
      assert html =~ ~s(status="out: 99")
    end

    test "chat_bubble label renders as assistant author", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "assistant", label: "My Agent"}
        )

      assert html =~ "<el-dm-chat"
      assert html =~ "My Agent"
      assert html =~ ~s(author="My Agent")
      assert html =~ ~s(align="start")
    end

    test "chat_bubble defaults author and avatar by role", _ctx do
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

      assert html =~ "<el-dm-chat"
      assert html =~ ~s(author="Assistant")
      assert html =~ ~s(avatar="AI")
    end

    test "chat_bubble uses user role defaults instead of arbitrary labels", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "user", label: "My Agent"}
        )

      assert html =~ "<el-dm-chat"
      refute html =~ "My Agent"
      assert html =~ ~s(author="You")
      assert html =~ ~s(avatar="U")
    end

    test "chat_bubble uses system role defaults instead of arbitrary labels", _ctx do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.chat_bubble role={assigns.role} label={assigns.label}>
              content
            </SynapsisWeb.CoreComponents.chat_bubble>
            """
          end,
          %{role: "system", label: "My Agent"}
        )

      assert html =~ "<el-dm-chat"
      refute html =~ "My Agent"
      assert html =~ ~s(author="System")
      assert html =~ ~s(avatar="S")
    end

    test "message_parts passes timestamp and token status to chat messages", _ctx do
      message = %Synapsis.Message{
        role: "assistant",
        token_count: 99,
        inserted_at: ~U[2026-05-26 16:29:00.000000Z],
        parts: [%Synapsis.Part.Text{content: "hello"}]
      }

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.message_parts
              message={assigns.message}
              assistant_label="Pi"
              assistant_avatar="π"
            />
            """
          end,
          %{message: message}
        )

      assert html =~ ~s(author="Pi")
      assert html =~ ~s(avatar="π")
      assert html =~ ~s(time="16:29:00")
      assert html =~ ~s(status="out: 99")
    end
  end
end
