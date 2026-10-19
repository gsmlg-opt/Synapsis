defmodule SynapsisWeb.AgentLive.SessionsTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Session.{PendingInputStore, Worker}
  alias Synapsis.Session.Worker.Persistence, as: SessionPersistence
  alias Synapsis.{AgentConfigs, Sessions}

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    on_exit(fn -> Synapsis.DataCase.clear_config_store(:provider) end)
    :ok
  end

  describe "agent sessions page" do
    test "disables LiveView parameter logging for Base64 image payloads" do
      assert %{log: false} = SynapsisWeb.AgentLive.Sessions.__live__()
    end

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

      render(view)
      assert chat_json(view) =~ "morning-briefing"
      assert chat_json(view) =~ "Test result"
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
      assert chat_snapshot(view).admission.canSubmit
      assert {:ok, %{status: "idle"}} = Synapsis.Sessions.get(session.id)
    end

    test "chat island owns the composer and idle steer is unavailable", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert has_element?(
               view,
               "#agent-chat-#{session.id}[phx-hook='SynapsisReactChat'][phx-update='ignore']"
             )

      refute has_element?(view, "el-dm-chat-input#message-input")
      refute chat_snapshot(view).admission.canSteer

      render_hook(view, "send_message", %{"value" => "   "})
      render_hook(view, "steer_message", %{"value" => "idle steer should not persist"})
      assert Sessions.get_messages(session.id) == []
    end

    test "send hook persists Base64 JSON images and clears after acceptance", %{conn: conn} do
      session = create_image_session()

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      render_hook(view, "send_message", %{
        "value" => "describe",
        "images" => [png_image_payload()]
      })

      assert_push_event(view, "clear_chat_input", %{})

      assert_eventually(fn ->
        Enum.any?(Sessions.get_messages(session.id), &(&1.role == "user"))
      end)

      assert %Synapsis.Message{
               parts: [
                 %Synapsis.Part.Text{content: "describe"},
                 %Synapsis.Part.Image{media_type: "image/png", data: data}
               ]
             } = Enum.find(Sessions.get_messages(session.id), &(&1.role == "user"))

      assert data == png_image_payload()["data"]
      assert_image_turn_completed(session)
      assert_receive {:image_provider_request, request}
      assert provider_request_has_image?(request)
    end

    test "send hook accepts an image-only prompt", %{conn: conn} do
      session = create_image_session()

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      render_hook(view, "send_message", %{"value" => "", "images" => [png_image_payload()]})

      assert_push_event(view, "clear_chat_input", %{})

      assert_eventually(fn ->
        Enum.any?(Sessions.get_messages(session.id), &(&1.role == "user"))
      end)

      assert %Synapsis.Message{parts: [%Synapsis.Part.Image{media_type: "image/png"}]} =
               Enum.find(Sessions.get_messages(session.id), &(&1.role == "user"))

      assert_image_turn_completed(session)
      assert_receive {:image_provider_request, request}
      assert provider_request_has_image?(request)
    end

    test "send hook retains image parts in a queued prompt", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      render_hook(view, "send_message", %{
        "value" => "queued image",
        "images" => [png_image_payload()]
      })

      assert_push_event(view, "clear_chat_input", %{})

      assert [
               %{
                 content: "queued image",
                 image_parts: [%Synapsis.Part.Image{media_type: "image/png"}]
               }
             ] = PendingInputStore.queued_prompts(session.id)
    end

    test "send hook rejects malformed image JSON without text-only fallback", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      html =
        render_hook(view, "send_message", %{
          "value" => "must not be sent",
          "images" => [%{png_image_payload() | "data" => "not-base64!"}]
        })

      assert html =~ "Invalid image attachment"
      refute_push_event(view, "clear_chat_input", %{})
      assert Sessions.get_messages(session.id) == []
      assert PendingInputStore.queued_prompts(session.id) == []
    end

    test "client image read errors use a fixed safe message", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      html = render_hook(view, "image_attachment_error", %{"message" => "private detail"})

      assert html =~ "Could not read image attachment"
      refute html =~ "private detail"
      assert Sessions.get_messages(session.id) == []
    end

    test "chat admits queue and steer while streaming or executing tools", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      for status <- ~w(streaming tool_executing) do
        assert {:ok, _session} = SessionPersistence.update_session_status(session.id, status)
        send(view.pid, {"session_status", %{status: status}})
        render(view)

        assert %{canSubmit: true, canSteer: true, sendLabel: "Queue"} =
                 chat_snapshot(view).admission

        assert chat_snapshot(view).runtime.phase == status
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

      html = chat_json(view)

      assert html =~ "queued follow-up"
      assert html =~ ~s("queued":true)
      assert Sessions.get_messages(session.id) == []

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = chat_json(view)

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

      html = chat_json(view)
      assert html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"done", %{}})

      html = chat_json(view)
      assert html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = chat_json(view)
      refute html =~ "first pending"
      assert html =~ "second pending"

      send(view.pid, {"input_started", %{id: "queued-prompt-2", kind: "prompt"}})

      html = chat_json(view)
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

      html = chat_json(view)
      assert html =~ "survives idle"

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = chat_json(view)
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

      html = chat_json(view)

      assert html =~ ~s("id":"queued-input-queued-prompt-1")
      assert html =~ ~s("id":"queued-input-queued-prompt-2")
      assert Enum.count(chat_snapshot(view).messages, &(&1.content == "same prompt")) == 2
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
      html = chat_json(view)

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
      assert chat_snapshot(view).admission.sendLabel == "Queue"
      refute has_element?(view, "el-dm-button[phx-click='retry']")
      assert chat_snapshot(view).admission.canSubmit
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

      html = chat_json(view)

      refute html =~ "prefer a smaller patch"
      assert Sessions.get_messages(session.id) == []
    end

    test "renders failed tool result immediately while streaming", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(view.pid, {"tool_use", %{tool: "file_read", tool_use_id: "tu_failed"}})

      assert chat_json(view) =~ "file_read"

      send(
        view.pid,
        {"tool_result", %{tool_use_id: "tu_failed", content: "Permission denied", is_error: true}}
      )

      html = chat_json(view)

      assert html =~ ~s("status":"error")
      assert html =~ "Permission denied"
    end

    @tag capture_log: true
    test "renders sent user message immediately before agent response", %{conn: conn} do
      bypass = Bypass.open()
      provider_name = "immediate_chat_#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        Synapsis.Provider.Registry.register(provider_name, %{
          type: "anthropic",
          api_key: "test-key",
          base_url: "http://localhost:#{bypass.port}"
        })

      on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        send(test_pid, {:provider_waiting, self()})

        receive do
          :reply_now -> :ok
        after
          5_000 -> flunk("provider response was not released")
        end

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

      render_hook(view, "send_message", %{"value" => "show this immediately"})

      assert chat_json(view) =~ "show this immediately"
      assert_receive {:provider_waiting, provider_pid}, 1_000
      assert chat_json(view) =~ "show this immediately"
      # Native preparation acknowledges persistence before starting the provider.
      messages = Sessions.get_messages(session.id)
      assert Enum.any?(messages, &(&1.role == "user")), "expected a user message to be persisted"
      refute Enum.any?(messages, &(&1.role == "assistant"))
      send(provider_pid, :reply_now)
      assert_eventually(fn -> length(Sessions.get_messages(session.id)) >= 2 end)
    end
  end

  describe "React chat protocol" do
    test "streaming deltas are ordered and sync recovers canonical text without changing mount data",
         %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      [initial] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#agent-chat-#{session.id}")
        |> LazyHTML.attribute("data-chat")

      scope = chat_scope(view)
      message_id = SynapsisWeb.AgentLive.SessionChat.live_id(session.id)

      send(view.pid, {"text_delta", %{text: "hello "}})
      render(view)

      assert_push_event(view, "chat:event", %{
        type: "chat.message",
        message_id: ^message_id,
        sequence: 1
      })

      assert_push_event(view, "chat:event", %{
        type: "chat.delta",
        message_id: ^message_id,
        sequence: 2,
        text: "hello "
      })

      send(view.pid, {"text_delta", %{text: "world"}})
      render(view)

      assert_push_event(view, "chat:event", %{
        type: "chat.delta",
        message_id: ^message_id,
        sequence: 3,
        text: "world"
      })

      send(view.pid, {"reasoning", %{text: "a short explanation"}})
      render(view)

      assert_push_event(view, "chat:event", %{
        type: "chat.message",
        message_id: ^message_id,
        sequence: 4,
        message: %{content: "hello world", metadata: %{reasoning: "a short explanation"}}
      })

      updated = render_hook(view, "chat.sync", scope)

      assert_push_event(view, "chat:event", %{
        type: "chat.snapshot",
        sequences: %{^message_id => 4},
        messages: [%{content: "hello world"}]
      })

      assert [initial] ==
               updated
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#agent-chat-#{session.id}")
               |> LazyHTML.attribute("data-chat")
    end

    test "completion replaces the transient assistant with durable ordered parts", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      assert {:ok, _} = Worker.set_subagents(session.id, false)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      send(view.pid, {"text_delta", %{text: "draft"}})
      render(view)

      {:ok, message} =
        Synapsis.Message.append(session.id, %{
          role: "assistant",
          parts: [
            %Synapsis.Part.Reasoning{content: "reason"},
            %Synapsis.Part.ToolUse{
              tool: "file_read",
              tool_use_id: "tool-1",
              input: %{path: "a.txt"},
              status: :complete
            },
            %Synapsis.Part.ToolResult{tool_use_id: "tool-1", content: "file contents"},
            %Synapsis.Part.Text{content: "final"}
          ]
        })

      send(view.pid, {"done", %{}})
      render(view)
      id = message.id

      assert_push_event(view, "chat:event", %{
        type: "chat.snapshot",
        runtime: %{active: false, phase: "idle"},
        messages: [
          %{
            id: ^id,
            content: "final",
            actions: [%{id: "regenerate"}],
            metadata: %{
              parts: [
                %{type: "reasoning"},
                %{type: "tool_use"},
                %{type: "tool_result"},
                %{type: "text"}
              ]
            }
          }
        ]
      })
    end

    test "accepted queued image sends acknowledge once and survive remount", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      params =
        Map.merge(chat_scope(view), %{
          "request_id" => "send-once",
          "text" => "look",
          "images" => [png_image_payload()]
        })

      socket = chat_socket(view)

      assert {:reply, %{status: "ok"}, accepted} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.send", params, socket)

      assert {:reply, %{status: "ok"}, _same} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.send", params, accepted)

      assert [%{content: "look", image_parts: [%Synapsis.Part.Image{}]}] =
               PendingInputStore.queued_prompts(session.id)

      {:ok, remounted, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      assert [%{metadata: %{queued: true, parts: [%{type: "text"}, %{type: "image"}]}}] =
               Enum.filter(chat_snapshot(remounted).messages, & &1.metadata[:queued])
    end

    test "invalid attachments and stale scope return errors without persistence", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      socket = chat_socket(view)

      params =
        Map.merge(chat_scope(view), %{
          "request_id" => "invalid-image",
          "text" => "must not send",
          "images" => [%{png_image_payload() | "data" => "not-base64!"}]
        })

      assert {:reply, %{status: "error", message: "Invalid image attachment"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.send", params, socket)

      assert {:reply, %{status: "error", message: "Conversation changed"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.send",
                 %{params | "conversation_id" => "old-session"},
                 socket
               )

      assert {:reply, %{status: "error", message: "Invalid request ID"}, rejected} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.send",
                 %{params | "request_id" => String.duplicate("x", 129), "images" => []},
                 socket
               )

      assert rejected.assigns.react_chat.requests == socket.assigns.react_chat.requests
      assert Sessions.get_messages(session.id) == []
    end

    test "switching sessions resets streaming state and accepted request IDs", %{conn: conn} do
      {:ok, first} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, second} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(first)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{first.id}")
      old_scope = chat_scope(view)

      render_hook(
        view,
        "chat.send",
        Map.merge(old_scope, %{"request_id" => "old-request", "text" => "queued"})
      )

      send(view.pid, {"text_delta", %{text: "old draft"}})
      render(view)

      render_patch(view, ~p"/agent/agents/main/sessions/#{second.id}")
      chat = chat_snapshot(view)
      assert chat.conversation_id == second.id
      assert chat.messages == []
      assert chat.sequences == %{}
      assert chat.requests == %{}

      assert {:reply, %{status: "error"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.stop",
                 old_scope,
                 chat_socket(view)
               )
    end

    test "active tool execution blocks regenerate and validates pending permission actions", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, message} =
        Synapsis.Message.append(session.id, %{
          role: "assistant",
          parts: [%Synapsis.Part.Text{content: "keep reply"}]
        })

      set_worker_running(session)

      assert {:ok, _session} =
               SessionPersistence.update_session_status(session.id, "tool_executing")

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      send(view.pid, {"session_status", %{status: "tool_executing"}})

      send(
        view.pid,
        {"permission_request",
         %{
           tool: "file_write",
           tool_use_id: "pending-tool",
           input: %{path: "a.txt"},
           level: "write"
         }}
      )

      render(view)
      scope = chat_scope(view)
      socket = chat_socket(view)
      assert Enum.find(chat_snapshot(view).messages, &(&1.id == message.id)).actions == []

      assert {:reply, %{status: "error"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(scope, %{"action" => "regenerate", "message_id" => message.id}),
                 socket
               )

      assert Enum.any?(Sessions.get_messages(session.id), &(&1.id == message.id))

      live_id = SynapsisWeb.AgentLive.SessionChat.live_id(session.id)

      params =
        Map.merge(scope, %{
          "action" => "approve_tool",
          "message_id" => live_id,
          "tool_use_id" => "unknown"
        })

      assert {:reply, %{status: "error"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.action", params, socket)

      assert {:reply, %{status: "ok"}, approved} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 %{params | "tool_use_id" => "pending-tool"},
                 socket
               )

      assert approved.assigns.permission_requests == []

      assert {:reply, %{status: "error"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 %{params | "tool_use_id" => "pending-tool"},
                 approved
               )
    end

    test "heartbeat and code-agent panels remain scoped transcript messages", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(
        view.pid,
        {:heartbeat_completed, "config",
         %{name: "briefing", executed_at: DateTime.utc_now(), result: "ready"}}
      )

      send(view.pid, {"code_agent_spawned", %{sub_session_id: "sub-1", prompt: "fix file"}})

      send(
        view.pid,
        {"code_agent_event",
         %{sub_session_id: "sub-1", event: "tool_use", payload: %{tool: "file_read"}}}
      )

      send(
        view.pid,
        {"code_agent_event", %{sub_session_id: "sub-1", event: "done", payload: %{text: "fixed"}}}
      )

      render(view)
      chat = chat_snapshot(view)

      assert %{
               metadata: %{
                 codeAgent: %{
                   prompt: "fix file",
                   status: "complete",
                   completion: "fixed",
                   tool_calls: [%{name: "file_read"}]
                 }
               }
             } = Enum.find(chat.messages, &(&1.id == "code-agent-sub-1"))

      heartbeat = Enum.find(chat.messages, & &1.metadata[:heartbeat])
      assert heartbeat.content == "ready"

      assert {:reply, %{status: "ok"}, socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(chat_scope(view), %{
                   "action" => "dismiss_heartbeat",
                   "message_id" => heartbeat.id
                 }),
                 chat_socket(view)
               )

      assert socket.assigns.heartbeat_notifications == []
    end
  end

  describe "ask_user questions" do
    test "projects registered questions and option descriptions while retaining Queue and Stop",
         %{conn: conn} do
      session = create_running_question_session()
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      options = [%{"label" => "Small change", "description" => "Keep the patch focused"}]
      {ref, task} = start_user_question(session, options)

      assert_eventually(fn -> chat_snapshot(view).metadata.userQuestions != [] end)
      chat = chat_snapshot(view)

      assert chat.metadata.userQuestions == [
               %{ref: ref, question: "Which approach?", options: options}
             ]

      assert %{phase: "waiting_for_user", active: true} = chat.runtime

      assert %{canSubmit: true, canSteer: false, allowWhileStreaming: true, sendLabel: "Queue"} =
               chat.admission

      assert chat.metadata.canStop

      assert Enum.find(
               chat.messages,
               &(&1.id == SynapsisWeb.AgentLive.SessionChat.live_id(session.id))
             ).status == "pending"

      refute Jason.encode!(chat.metadata) =~ "deadline_ms"
      refute Jason.encode!(chat.metadata) =~ "owner"

      render_hook(
        view,
        "chat.send",
        Map.merge(chat_scope(view), %{
          "request_id" => "queue-during-question",
          "text" => "follow-up prompt"
        })
      )

      assert [%{content: "follow-up prompt"}] = PendingInputStore.queued_prompts(session.id)
      params = answer_params(view, ref, "Small change", "answer-question")

      assert {:reply, %{status: "ok"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 params,
                 chat_socket(view)
               )

      assert {:ok, "Small change"} = Task.await(task, 1_000)
    end

    test "answer acceptance is deduplicated and closes the question in every mounted view", %{
      conn: conn
    } do
      session = create_running_question_session()
      {:ok, first, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      {:ok, second, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      {ref, task} = start_user_question(session)
      assert_eventually(fn -> length(chat_snapshot(first).metadata.userQuestions) == 1 end)
      assert_eventually(fn -> length(chat_snapshot(second).metadata.userQuestions) == 1 end)
      second_socket = chat_socket(second)
      second_params = answer_params(second, ref, "a second answer", "second-answer")
      params = answer_params(first, ref, "chosen response", "answer-once")

      assert {:reply, %{status: "ok"}, accepted} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 params,
                 chat_socket(first)
               )

      assert {:reply, %{status: "ok"}, _same} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.action", params, accepted)

      assert {:ok, "chosen response"} = Task.await(task, 1_000)

      assert {:reply, %{status: "error", message: "Question is no longer pending"}, rejected} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 second_params,
                 second_socket
               )

      assert rejected.assigns.user_questions == []
      assert_eventually(fn -> chat_snapshot(first).metadata.userQuestions == [] end)
      assert_eventually(fn -> chat_snapshot(second).metadata.userQuestions == [] end)
      assert chat_snapshot(first).runtime.phase == "streaming"
      assert chat_snapshot(first).admission.canSteer
      assert PendingInputStore.queued_prompts(session.id) == []
      assert PendingInputStore.queued_steers(session.id) == []
      assert Sessions.get_messages(session.id) == []
    end

    test "mount, reselect and sync recover questions from the live Worker", %{conn: conn} do
      session = create_running_question_session()
      {ref, task} = start_user_question(session)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert [%{ref: ^ref}] = chat_snapshot(view).metadata.userQuestions
      old_scope = chat_scope(view)

      {:ok, other} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      render_patch(view, ~p"/agent/agents/main/sessions/#{other.id}")
      assert chat_snapshot(view).metadata.userQuestions == []
      send(view.pid, {:ask_user, ref, %{session_id: session.id, question: "old question"}})
      render(view)
      assert chat_snapshot(view).metadata.userQuestions == []

      assert {:reply, %{status: "error", message: "Conversation changed"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(old_scope, %{
                   "action" => "answer_question",
                   "ref" => ref,
                   "response" => "stale",
                   "request_id" => "stale-answer"
                 }),
                 chat_socket(view)
               )

      assert [%{ref: ^ref}] = Worker.snapshot(session.id).user_questions

      render_patch(view, ~p"/agent/agents/main/sessions/#{session.id}")
      assert [%{ref: ^ref}] = chat_snapshot(view).metadata.userQuestions
      stale_socket = Phoenix.Component.assign(chat_socket(view), :user_questions, [])

      assert {:reply, %{status: "ok"}, recovered} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.sync",
                 chat_scope(view),
                 stale_socket
               )

      assert [%{ref: ^ref}] = recovered.assigns.react_chat.metadata.userQuestions
      assert recovered.assigns.react_chat.runtime.phase == "waiting_for_user"

      assert :ok = Worker.answer_question(session.id, ref, "recovered answer")
      assert {:ok, "recovered answer"} = Task.await(task, 1_000)
    end

    test "rejects invalid, oversized and foreign answers without consuming the active question",
         %{conn: conn} do
      session = create_running_question_session()
      {ref, task} = start_user_question(session)
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      socket = chat_socket(view)

      for response <- ["   ", String.duplicate("x", 256_001), %{"value" => "not a string"}] do
        params = answer_params(view, ref, response, Ecto.UUID.generate())

        assert {:reply, %{status: "error", message: "Invalid question response"}, _socket} =
                 SynapsisWeb.AgentLive.Sessions.handle_event("chat.action", params, socket)
      end

      params = answer_params(view, ref, "valid text", "valid-answer")

      assert {:reply, %{status: "error", message: "Invalid question response"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.delete(params, "request_id"),
                 socket
               )

      assert {:reply, %{status: "error", message: "Invalid question response"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 %{params | "ref" => String.duplicate("r", 129)},
                 socket
               )

      assert {:reply, %{status: "error", message: "Question is no longer pending"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 %{params | "ref" => Ecto.UUID.generate()},
                 socket
               )

      assert [%{ref: ^ref}] = Worker.snapshot(session.id).user_questions

      {:ok, other} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, other_view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{other.id}")

      assert {:reply, %{status: "error", message: "Question is no longer pending"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 answer_params(other_view, ref, "wrong session", "foreign-answer"),
                 chat_socket(other_view)
               )

      assert [%{ref: ^ref}] = Worker.snapshot(session.id).user_questions
      assert PendingInputStore.queued_prompts(session.id) == []
      assert PendingInputStore.queued_steers(session.id) == []

      assert {:reply, %{status: "ok"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.action", params, socket)

      assert {:ok, "valid text"} = Task.await(task, 1_000)
    end

    test "owner exit removes pending questions through the closed event", %{conn: conn} do
      session = create_running_question_session()
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      {_ref, task} = start_user_question(session)
      assert_eventually(fn -> length(chat_snapshot(view).metadata.userQuestions) == 1 end)
      Task.shutdown(task, :brutal_kill)
      assert_eventually(fn -> chat_snapshot(view).metadata.userQuestions == [] end)
      assert chat_snapshot(view).runtime.phase == "streaming"
    end

    test "stop, completion and failure clear the question projection", %{conn: conn} do
      session = create_running_question_session()
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      {ref, task} = start_user_question(session)
      assert_eventually(fn -> length(chat_snapshot(view).metadata.userQuestions) == 1 end)
      socket = chat_socket(view)

      for event <- [{"done", %{}}, {"error", %{message: "failed"}}] do
        assert {:noreply, terminal} = SynapsisWeb.AgentLive.Sessions.handle_info(event, socket)
        assert terminal.assigns.react_chat.metadata.userQuestions == []
        refute terminal.assigns.react_chat.runtime.active
      end

      assert {:reply, %{status: "ok"}, stopped} =
               SynapsisWeb.AgentLive.Sessions.handle_event("chat.stop", chat_scope(view), socket)

      assert stopped.assigns.react_chat.metadata.userQuestions == []
      assert_eventually(fn -> Worker.snapshot(session.id).user_questions == [] end)
      assert_eventually(fn -> chat_snapshot(view).metadata.userQuestions == [] end)

      assert {:reply, %{status: "error", message: "Question is no longer pending"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 answer_params(view, ref, "after cancellation", "cancelled-answer"),
                 chat_socket(view)
               )

      Task.shutdown(task, :brutal_kill)
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

    test "message_parts renders a durable image part", _ctx do
      message = %Synapsis.Message{
        role: "user",
        inserted_at: ~U[2026-05-26 16:29:00.000000Z],
        parts: [%Synapsis.Part.Image{media_type: "image/png", data: "base64data", path: nil}]
      }

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SynapsisWeb.CoreComponents.message_parts message={assigns.message} />
            """
          end,
          %{message: message}
        )

      assert html =~ ~s(alt="Attached image")
      assert html =~ ~s(src="data:image/png;base64,base64data")
      assert html =~ "max-w-full"
      assert html =~ "max-h-96"
      assert html =~ "rounded-lg"
      assert html =~ "border-outline-variant"
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
    assert {:ok, _session} = Worker.set_subagents(session.id, false)
    assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "streaming")
    assert [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

    :sys.replace_state(pid, fn {:idle, data} ->
      {:generating, %{data | stream_ref: make_ref(), engine_node: :llm_stream}}
    end)
  end

  defp create_running_question_session do
    {:ok, session} =
      Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

    set_worker_running(session)
    session
  end

  defp start_user_question(session, options \\ nil) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

    task =
      Task.async(fn ->
        Synapsis.Tool.AskUser.execute(%{"question" => "Which approach?", "options" => options}, %{
          session_id: session.id
        })
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:ask_user, ref, _payload}, 1_000

    assert_eventually(fn ->
      Enum.any?(Worker.snapshot(session.id).user_questions, &(&1.ref == ref))
    end)

    {ref, task}
  end

  defp answer_params(view, ref, response, request_id) do
    Map.merge(chat_scope(view), %{
      "action" => "answer_question",
      "ref" => ref,
      "response" => response,
      "request_id" => request_id
    })
  end

  defp chat_socket(view) do
    render(view)
    :sys.get_state(view.pid).socket
  end

  defp chat_snapshot(view), do: chat_socket(view).assigns.react_chat
  defp chat_json(view), do: Jason.encode!(chat_snapshot(view))

  defp chat_scope(view) do
    chat = chat_snapshot(view)
    %{"id" => chat.id, "conversation_id" => chat.conversation_id}
  end

  defp png_image_payload do
    %{
      "name" => "pixel.png",
      "media_type" => "image/png",
      "data" =>
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVQI12P4z8AAAAACAAHiIbwzAAAAAElFTkSuQmCC"
    }
  end

  defp create_image_session do
    bypass = Bypass.open()
    provider_name = "image_chat_#{System.unique_integer([:positive])}"
    test_pid = self()

    assert :ok =
             Synapsis.Provider.Registry.register(provider_name, %{
               type: "anthropic",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             })

    on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:image_provider_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, """
      data: {"type":"message_start","message":{"id":"msg_image"}}

      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ack"}}

      data: {"type":"message_stop"}

      """)
    end)

    assert {:ok, session} =
             Sessions.create("__global__", %{
               provider: provider_name,
               model: "test-model",
               agent: "main"
             })

    session
  end

  defp provider_request_has_image?(request) do
    Enum.any?(request["messages"], fn message ->
      Enum.any?(message["content"], &(&1["type"] == "image"))
    end)
  end

  defp assert_image_turn_completed(session) do
    assert_eventually(fn ->
      Enum.any?(Sessions.get_messages(session.id), fn message ->
        message.role == "assistant" and
          Enum.any?(message.parts, &match?(%Synapsis.Part.Text{content: "ack"}, &1))
      end) and
        get_in(Worker.snapshot(session.id), [:subagents, :root, :status]) == :completed
    end)
  end
end
