defmodule SynapsisWeb.AgentLive.SessionsTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Session.Worker.Persistence, as: SessionPersistence
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
      assert {:ok, %{status: "idle"}} = Synapsis.Sessions.get(session.id)
    end

    test "chat input uses DuskMoon chat input send event", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(view, "el-dm-chat-input#message-input[phx-hook='WebComponentHook']")

      assert has_element?(
               view,
               "el-dm-chat-input#message-input[duskmoon-send-quick-action='steer_message']"
             )

      render_hook(view, "send_message", %{"value" => "   "})

      assert Sessions.get_messages(session.id) == []
    end

    test "chat input remains enabled while session is running", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      for status <- ~w(streaming tool_executing) do
        assert {:ok, _session} = SessionPersistence.update_session_status(session.id, status)

        send(view.pid, {"session_status", %{status: status}})

        html = render(view)
        refute has_element?(view, "el-dm-chat-input#message-input[disabled]")

        assert has_element?(
                 view,
                 "el-dm-chat-input#message-input[duskmoon-send-quick-action='steer_message']"
               )

        assert html =~ ~s(send-label="Queue")
      end
    end

    test "renders queued prompts as transient pending input and removes them when started", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
      send(view.pid, {"session_status", %{status: "streaming"}})

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-1", kind: "prompt", content: "queued follow-up"}}
      )

      html = render(view)

      assert html =~ "queued follow-up"
      assert html =~ "Queued"
      assert Sessions.get_messages(session.id) == []

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = render(view)

      refute html =~ "queued follow-up"
      assert Sessions.get_messages(session.id) == []
    end

    test "queued steer input is advisory and does not render as a durable user bubble", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
      send(view.pid, {"session_status", %{status: "streaming"}})

      send(
        view.pid,
        {"input_queued",
         %{id: "queued-steer-1", kind: "steer", content: "prefer a smaller patch"}}
      )

      html = render(view)

      refute html =~ "prefer a smaller patch"
      assert Sessions.get_messages(session.id) == []
    end

    test "renders failed tool result immediately while streaming", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(view.pid, {"tool_use", %{tool: "file_read", tool_use_id: "tu_failed"}})

      assert render(view) =~ "file_read"

      send(
        view.pid,
        {"tool_result", %{tool_use_id: "tu_failed", content: "Permission denied", is_error: true}}
      )

      html = render(view)

      assert html =~ ~s(status="error")
      assert html =~ "Permission denied"
    end

    @tag capture_log: true
    test "renders sent user message immediately before agent response", %{conn: conn} do
      bypass = Bypass.open()
      provider_name = "immediate_chat_#{System.unique_integer([:positive])}"

      :ok =
        Synapsis.Provider.Registry.register(provider_name, %{
          type: "anthropic",
          api_key: "test-key",
          base_url: "http://localhost:#{bypass.port}"
        })

      on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"message_start","message":{"id":"msg_immediate"}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ack"}}

        data: {"type":"message_stop"}

        """)
      end)

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: provider_name,
          model: "claude-sonnet-4-20250514",
          agent: "main"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      html = render_hook(view, "send_message", %{"value" => "show this immediately"})

      assert html =~ "show this immediately"
      # The user message must be written before the agent responds.
      # Don't assert exactly 1 message — on fast CI the assistant reply can
      # already be written by the time we check.
      messages = Sessions.get_messages(session.id)
      assert Enum.any?(messages, &(&1.role == "user")), "expected a user message to be persisted"
      assert_eventually(fn -> length(Sessions.get_messages(session.id)) >= 2 end)
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

    test "message_parts renders a regenerate button for assistant messages when allowed", _ctx do
      message = %Synapsis.Message{
        id: "msg-123",
        role: "assistant",
        parts: [%Synapsis.Part.Text{content: "hello"}]
      }

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.message_parts
              message={assigns.message}
              can_regenerate={true}
            />
            """
          end,
          %{message: message}
        )

      assert html =~ ~s(phx-click="regenerate")
      assert html =~ ~s(phx-value-id="msg-123")
      assert html =~ "Regenerate"
    end

    test "message_parts hides the regenerate button while streaming", _ctx do
      message = %Synapsis.Message{
        id: "msg-123",
        role: "assistant",
        parts: [%Synapsis.Part.Text{content: "hello"}]
      }

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.message_parts
              message={assigns.message}
              can_regenerate={false}
            />
            """
          end,
          %{message: message}
        )

      refute html =~ ~s(phx-click="regenerate")
    end

    test "message_parts never offers regenerate for user messages", _ctx do
      message = %Synapsis.Message{
        id: "user-1",
        role: "user",
        parts: [%Synapsis.Part.Text{content: "a question"}]
      }

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.message_parts
              message={assigns.message}
              can_regenerate={true}
            />
            """
          end,
          %{message: message}
        )

      refute html =~ ~s(phx-click="regenerate")
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")
end
