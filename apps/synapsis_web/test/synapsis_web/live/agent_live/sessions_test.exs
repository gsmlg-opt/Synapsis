defmodule SynapsisWeb.AgentLive.SessionsTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Session.PendingInputStore
  alias Synapsis.Session.Worker.Persistence, as: SessionPersistence
  alias Synapsis.{AgentConfigs, Sessions}

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
      refute has_element?(view, "div[data-session-row='#{session.id}']", "anthropic/test")
    end

    test "new session button creates a session directly without confirmation step", %{conn: conn} do
      name = "instant_#{System.unique_integer([:positive])}"

      {:ok, agent} =
        AgentConfigs.create(%{
          name: name,
          label: "Instant",
          provider: "openai",
          model: "gpt-4.1"
        })

      {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.name}/sessions")

      refute html =~ "Create Session"

      assert has_element?(
               view,
               "aside el-dm-button[phx-click='create_session'][variant='primary']",
               "New Session"
             )

      view
      |> element(
        "aside el-dm-button[phx-click='create_session'][variant='primary']",
        "New Session"
      )
      |> render_click()

      {:ok, [session]} = Sessions.list(agent.name, limit: 10)
      assert session.provider == "openai"
      assert session.model == "gpt-4.1"
      assert_patch(view, ~p"/agent/agents/#{agent.name}/sessions/#{session.id}")
    end

    test "session delete uses an in-app confirmation modal", %{conn: conn} do
      {:ok, active_session} =
        Sessions.create("__global__", %{
          provider: "anthropic",
          model: "test",
          agent: "main",
          title: "Keep me"
        })

      {:ok, doomed_session} =
        Sessions.create("__global__", %{
          provider: "anthropic",
          model: "test",
          agent: "main",
          title: "Delete me"
        })

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{active_session.id}")

      refute html =~ "Delete session?"
      refute has_element?(view, "el-dm-button[data-confirm]")
      refute has_element?(view, "el-dm-button[onclick='event.stopPropagation()']")

      assert has_element?(
               view,
               "button[type='button'][phx-click='confirm_delete_session'][phx-value-id='#{doomed_session.id}']"
             )

      view
      |> element(
        "button[phx-click='confirm_delete_session'][phx-value-id='#{doomed_session.id}']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "Delete session?"
      assert html =~ "Delete me"
      assert {:ok, _session} = Sessions.get(doomed_session.id)

      view
      |> element(
        "#delete-session-modal el-dm-button[phx-click='cancel_delete_session']",
        "Cancel"
      )
      |> render_click()

      refute render(view) =~ "Delete session?"
      assert {:ok, _session} = Sessions.get(doomed_session.id)

      view
      |> element(
        "button[phx-click='confirm_delete_session'][phx-value-id='#{doomed_session.id}']"
      )
      |> render_click()

      view
      |> element("#delete-session-modal el-dm-button[phx-click='delete_session']", "Delete")
      |> render_click()

      assert {:error, :not_found} = Sessions.get(doomed_session.id)
      refute has_element?(view, "div[data-session-row='#{doomed_session.id}']")
    end

    test "session metadata shows only the agent label without model", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(view, "[data-session-agent-meta]", "Main")
      refute has_element?(view, "[data-session-agent-meta]", "anthropic/test")
      refute html =~ "Main · anthropic/test"
      refute has_element?(view, "div[data-session-row='#{session.id}']", "anthropic/test")
      assert has_element?(view, "div[data-session-row='#{session.id}']", "Main")
    end

    test "renders session context and current model next to status", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      assert {:ok, _message} =
               Synapsis.Message.append(session.id, %Synapsis.Message{
                 role: "user",
                 parts: [%Synapsis.Part.Text{content: "hello"}],
                 token_count: 420
               })

      assert {:ok, _message} =
               Synapsis.Message.append(session.id, %Synapsis.Message{
                 role: "assistant",
                 parts: [%Synapsis.Part.Text{content: "world"}],
                 token_count: 1080
               })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(
               view,
               "[data-session-status-meta]",
               "Context: 1.5K tokens Model: test idle"
             )
    end

    test "renders personality indicator with primary/70 style in session header", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, _view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      # Personality name appears in the styled span (text-primary/70 class)
      assert html =~ "text-primary/70"
      assert html =~ "Main"
      refute html =~ "anthropic/test"
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
      assert render(view) =~ "Main"
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

    test "chat input uses DuskMoon send event and hides idle steer quick action", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(view, "el-dm-chat-input#message-input[phx-hook='WebComponentHook']")

      refute has_element?(
               view,
               "el-dm-chat-input#message-input[duskmoon-send-quick-action='steer_message']"
             )

      render_hook(view, "send_message", %{"value" => "   "})

      html = render_hook(view, "steer_message", %{"value" => "idle steer should not persist"})

      refute html =~ "idle steer should not persist"
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

    test "queued prompts survive done until each matching input starts", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
      send(view.pid, {"session_status", %{status: "streaming"}})

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-1", kind: "prompt", content: "first pending"}}
      )

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-2", kind: "prompt", content: "second pending"}}
      )

      html = render(view)
      assert html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"done", %{}})

      html = render(view)
      assert html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = render(view)
      refute html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"input_started", %{id: "queued-prompt-2", kind: "prompt"}})

      html = render(view)
      refute html =~ "first pending"
      refute html =~ "second pending"
    end

    test "queued prompt survives idle status until it starts", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
      send(view.pid, {"session_status", %{status: "streaming"}})

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-1", kind: "prompt", content: "survives idle"}}
      )

      send(view.pid, {"session_status", %{status: "idle"}})

      html = render(view)
      assert html =~ "survives idle"

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = render(view)
      refute html =~ "survives idle"
    end

    test "renders duplicate queued prompts with different ids", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
      send(view.pid, {"session_status", %{status: "streaming"}})

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-1", kind: "prompt", content: "same prompt"}}
      )

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-2", kind: "prompt", content: "same prompt"}}
      )

      html = render(view)

      assert html =~ ~s(id="queued-input-queued-prompt-1")
      assert html =~ ~s(id="queued-input-queued-prompt-2")
      assert occurrence_count(html, "same prompt") == 2
      assert Sessions.get_messages(session.id) == []
    end

    test "send hook queues prompt while worker is running", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
      render_hook(view, "send_message", %{"value" => "queued through hook"})

      assert_receive {"input_queued",
                      %{id: _id, kind: "prompt", content: "queued through hook"} = payload}

      send(view.pid, {"input_queued", payload})
      html = render(view)

      assert html =~ "queued through hook"
      assert Sessions.get_messages(session.id) == []
    end

    test "running queue failure keeps running UI status", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)

      for index <- 1..25 do
        assert {:ok, _input} =
                 PendingInputStore.append_prompt(session.id, "stored prompt #{index}", [])
      end

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      html = render_hook(view, "send_message", %{"value" => "overflow prompt"})

      assert html =~ "Failed to queue message"
      assert html =~ ~s(send-label="Queue")
      refute html =~ "Retry"
      refute has_element?(view, "el-dm-chat-input#message-input[disabled]")
      assert Sessions.get_messages(session.id) == []
    end

    test "steer hook queues advisory input while running without rendering a bubble", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
      html = render_hook(view, "steer_message", %{"value" => "keep edits minimal"})

      assert_receive {"input_queued", %{id: _id, kind: "steer", content: "keep edits minimal"}}

      refute html =~ "keep edits minimal"
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

  defp set_worker_running(session) do
    assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
    assert [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

    :sys.replace_state(pid, fn {:idle, data} ->
      {:generating, %{data | stream_ref: make_ref(), engine_node: :llm_stream}}
    end)
  end

  defp occurrence_count(text, pattern) do
    text
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
