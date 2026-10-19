defmodule SynapsisWeb.AgentLive.SessionsSubagentsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.Session.Worker
  alias Synapsis.{Sessions, Session}

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    on_exit(fn -> Synapsis.DataCase.clear_config_store(:provider) end)
    :ok
  end

  test "session subagents start enabled and opting out persists across reconnect", %{conn: conn} do
    session = create_session()
    {:ok, view, _} = live(conn, route(session))

    assert has_element?(
             view,
             "#session-subagents-toggle[aria-pressed='true']",
             "Subagents enabled"
           )

    assert has_element?(view, "#session-subagents", "0 agents")

    view |> element("#session-subagents-toggle") |> render_click()
    assert {:ok, %Session{config: %{"subagents" => false}}} = Sessions.get(session.id)

    assert has_element?(
             view,
             "#session-subagents-toggle[aria-pressed='false']",
             "Subagents disabled"
           )

    {:ok, reconnected, _} = live(conn, route(session))
    assert has_element?(reconnected, "#session-subagents-toggle[aria-pressed='false']")
    refute has_element?(reconnected, "#session-subagents")

    reconnected |> element("#session-subagents-toggle") |> render_click()
    assert {:ok, %Session{config: %{"subagents" => true}}} = Sessions.get(session.id)
    assert has_element?(reconnected, "#session-subagents-toggle[aria-pressed='true']")
    assert has_element?(reconnected, "#session-subagents", "0 agents")
  end

  test "roster comes from the live worker on mount and reconnect and accepts updates", %{
    conn: conn
  } do
    session = create_session()
    roster = %{agents: [%{name: "/root/research", status: :running}]}
    set_projection(session, roster, [])
    {:ok, view, _} = live(conn, route(session))
    assert has_element?(view, "#session-subagents", "/root/research")
    assert has_element?(view, "#session-subagents", "Running")
    refute has_element?(view, "#session-subagents", "Historical")
    assert has_element?(view, "#session-subagents-toggle[disabled]")

    finished = %{
      agents: [%{name: "/root/research", status: :completed, historical: true, resident: false}]
    }

    set_projection(session, finished, [])
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session.id}", {"subagents", finished})
    assert has_element?(view, "#session-subagents", "Completed")
    refute has_element?(view, "#session-subagents-toggle[disabled]")

    {:ok, reconnected, _} = live(conn, route(session))
    assert has_element?(reconnected, "#session-subagents", "/root/research")
    assert has_element?(reconnected, "#session-subagents", "Completed")
    assert has_element?(reconnected, "#session-subagents", "Historical")
  end

  test "subagent sessions hide retry and regenerate while legacy sessions retain them", %{
    conn: conn
  } do
    session = create_session()
    assert {:ok, _} = Worker.set_subagents(session.id, false)

    {:ok, message} =
      Synapsis.Message.append(session.id, %{
        role: "assistant",
        parts: [%Synapsis.Part.Text{content: "Previous response"}]
      })

    {:ok, view, _} = live(conn, route(session))
    assert [%{id: "regenerate"}] = hd(chat_snapshot(view).messages).actions
    assert chat_snapshot(view).admission.canSubmit

    send(view.pid, {"session_status", %{status: "error"}})
    assert has_element?(view, "el-dm-button[phx-click='retry']")
    assert chat_snapshot(view).admission.canRetry

    send(view.pid, {"session_status", %{status: "idle"}})
    view |> element("#session-subagents-toggle") |> render_click()
    assert hd(chat_snapshot(view).messages).actions == []

    chat = chat_snapshot(view)
    scope = %{"id" => chat.id, "conversation_id" => chat.conversation_id}

    assert {:reply, %{status: "error"}, _} =
             SynapsisWeb.AgentLive.Sessions.handle_event(
               "chat.action",
               Map.merge(scope, %{"action" => "regenerate", "message_id" => message.id}),
               :sys.get_state(view.pid).socket
             )

    send(view.pid, {"session_status", %{status: "error"}})
    refute has_element?(view, "el-dm-button[phx-click='retry']")
    refute chat_snapshot(view).admission.canRetry

    assert {:reply, %{status: "error"}, _} =
             SynapsisWeb.AgentLive.Sessions.handle_event(
               "chat.retry",
               scope,
               :sys.get_state(view.pid).socket
             )
  end

  test "busy sessions cannot change subagents even through a forged toggle", %{conn: conn} do
    session = create_session()
    [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

    :sys.replace_state(pid, fn {:idle, data} ->
      {:generating, %{data | stream_ref: make_ref(), engine_node: :llm_stream}}
    end)

    {:ok, view, _} = live(conn, route(session))
    assert has_element?(view, "#session-subagents-toggle[disabled]")
    render_click(view, "toggle_subagents", %{})
    assert {:ok, saved} = Sessions.get(session.id)
    assert Session.subagents_enabled?(saved)
    assert render(view) =~ "Subagents can be changed when the session and its agents are idle"
  end

  test "pending approvals are restored and allow and deny target their exact interaction", %{
    conn: conn
  } do
    session = create_session()
    owner = self()
    adapter = spawn(fn -> adapter_loop(owner) end)
    on_exit(fn -> send(adapter, :stop) end)
    pending = [permission("allow-this"), permission("deny-this")]
    set_projection(session, %{agents: []}, pending, adapter)

    {:ok, view, _} = live(conn, route(session))
    assert has_element?(view, "[data-runtime-permission='allow-this']", "exec_command")
    assert has_element?(view, "[data-runtime-permission='deny-this']", "/root/research")

    view
    |> element("[data-runtime-permission='allow-this'] el-dm-button[phx-value-decision='allow']")
    |> render_click()

    assert_receive {:runtime_decision, "allow-this", true}
    refute has_element?(view, "[data-runtime-permission='allow-this']")
    assert has_element?(view, "[data-runtime-permission='deny-this']")

    view
    |> element("[data-runtime-permission='deny-this'] el-dm-button[phx-value-decision='deny']")
    |> render_click()

    assert_receive {:runtime_decision, "deny-this", false}
    assert Worker.snapshot(session.id).runtime_permissions == []
    refute has_element?(view, "[data-runtime-permission]")
  end

  test "foreign interaction ids and malformed decisions never reach the worker adapter", %{
    conn: conn
  } do
    session = create_session()
    owner = self()
    adapter = spawn(fn -> adapter_loop(owner) end)
    on_exit(fn -> send(adapter, :stop) end)
    set_projection(session, %{agents: []}, [permission("current")], adapter)
    {:ok, view, _} = live(conn, route(session))

    render_click(view, "resolve_runtime_permission", %{
      "interaction-id" => "another-session",
      "decision" => "allow"
    })

    render_click(view, "resolve_runtime_permission", %{
      "interaction-id" => "current",
      "decision" => "yes"
    })

    assert has_element?(view, "[data-runtime-permission='current']")
    assert [%{interaction_id: "current"}] = Worker.snapshot(session.id).runtime_permissions

    other = create_session()
    render_patch(view, route(other))
    refute has_element?(view, "[data-runtime-permission='current']")

    render_click(view, "resolve_runtime_permission", %{
      "interaction-id" => "current",
      "decision" => "allow"
    })

    assert [%{interaction_id: "current"}] = Worker.snapshot(session.id).runtime_permissions
    refute_receive {:runtime_decision, _, _}, 25
  end

  test "a stale approval stays visible when the worker rejects the decision", %{conn: conn} do
    session = create_session()
    set_projection(session, %{agents: []}, [permission("expired")])
    {:ok, view, _} = live(conn, route(session))
    set_projection(session, %{agents: []}, [])

    render_click(view, "resolve_runtime_permission", %{
      "interaction-id" => "expired",
      "decision" => "allow"
    })

    assert has_element?(view, "[data-runtime-permission='expired']")
    assert render(view) =~ "This approval is no longer available"
  end

  test "recovery and unavailable status remain visible and disable subagents on reconnect", %{
    conn: conn
  } do
    session = create_session()
    roster = %{agents: [], recovery_required: true, root: %{status: :running}}
    set_projection(session, roster, [])
    {:ok, view, _} = live(conn, route(session))
    assert has_element?(view, "#session-subagents", "Recovery required")
    assert has_element?(view, "#session-subagents-toggle[disabled]")
    refute chat_snapshot(view).admission.canSubmit

    unknown = %{agents: [], root: %{status: :unknown_outcome}}
    set_projection(session, unknown, [])
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session.id}", {"subagents", unknown})
    assert has_element?(view, "#session-subagents", "Needs attention")
    refute chat_snapshot(view).admission.canSubmit

    {:ok, reconnected, _} = live(conn, route(session))
    assert has_element?(reconnected, "#session-subagents", "Recovery required")
    assert has_element?(reconnected, "#session-subagents-toggle[disabled]")
    refute chat_snapshot(reconnected).admission.canSubmit

    set_projection(session, %{agents: [], error: :storage_unavailable}, [])
    {:ok, unavailable, _} = live(conn, route(session))

    assert has_element?(
             unavailable,
             "#session-subagents",
             "Agent status is temporarily unavailable"
           )

    assert has_element?(unavailable, "#session-subagents-toggle[disabled]")
    refute chat_snapshot(unavailable).admission.canSubmit
  end

  defp chat_snapshot(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns.react_chat
  end

  defp create_session do
    {:ok, session} =
      Sessions.create("main", %{provider: "anthropic", model: "test", agent: "main"})

    session
  end

  defp route(session), do: ~p"/agent/agents/main/sessions/#{session.id}"

  defp permission(id) do
    %{
      interaction_id: id,
      request: %{tool_name: "exec_command", arguments: %{"cmd" => "mix test"}},
      child: %{name: "/root/research"}
    }
  end

  defp set_projection(session, roster, pending, adapter \\ nil) do
    [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

    :sys.replace_state(pid, fn {state, data} ->
      {state,
       %{data | runtime_roster: roster, runtime_permissions: pending, runtime_pid: adapter}}
    end)
  end

  defp adapter_loop(owner) do
    receive do
      {:"$gen_cast", {:resolve, id, decision}} ->
        send(owner, {:runtime_decision, id, decision})
        adapter_loop(owner)

      :stop ->
        :ok
    end
  end
end
