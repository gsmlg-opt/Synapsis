defmodule SynapsisWeb.AgentLive.SessionsTest do
  use SynapsisWeb.ConnCase

  import Phoenix.Component

  alias Synapsis.Session.{PendingInputStore, Worker}
  alias Synapsis.Session.Worker.Persistence, as: SessionPersistence
  alias Synapsis.{AgentConfigs, Sessions}

  def refresh_mcp, do: %{}

  test "session creation explains an unavailable agent model and refreshes readiness", %{
    conn: conn
  } do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "live-session-provider",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "live-session-agent",
        provider: provider.name,
        model: "chosen-model"
      })

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.name}/sessions")
    refute has_element?(view, "aside button[phx-click='create_session']:not([disabled])")

    assert render_hook(view, "create_session", %{}) =~
             "Configure an available model in agent settings"

    {:ok, _} = Synapsis.Models.create(%{provider_id: provider.id, model: agent.model})
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})
    assert has_element?(view, "aside button[phx-click='create_session']:not([disabled])")
    assert {:ok, _} = Synapsis.Providers.delete(provider.id)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})
    refute has_element?(view, "aside button[phx-click='create_session']:not([disabled])")
    assert {:ok, []} = Sessions.list(agent.name)
  end

  test "sessions created from the UI record an attending user for ask_user", %{conn: conn} do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "attended-session-provider",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, _model} = Synapsis.Models.create(%{provider_id: provider.id, model: "chosen-model"})

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "attended-session-agent",
        provider: provider.name,
        model: "chosen-model"
      })

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.name}/sessions")
    render_hook(view, "create_session", %{})
    assert {:ok, [session]} = Sessions.list(agent.name)
    on_exit(fn -> Sessions.delete(session.id) end)

    assert session.config["interactive"] == true

    assert %{mode: :interactive, allow_execute: :allow} =
             Synapsis.Session.Store.get_value(session.id, "permission")
  end

  setup do
    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh_mcp, []})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:model)
    Synapsis.DataCase.clear_config_store(:agent)
    :ok = AgentConfigs.seed_defaults()
    on_exit(fn -> Synapsis.DataCase.clear_config_store(:provider) end)
    :ok
  end

  test "saving a replacement agent model refreshes an already open session page", %{conn: conn} do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "replacement-agent-provider",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, model} = Synapsis.Models.create(%{provider_id: provider.id, model: "replacement"})
    {:ok, agent} = AgentConfigs.create(%{name: "replacement-agent"})
    {:ok, sessions_view, _} = live(conn, ~p"/agent/agents/#{agent.name}/sessions")

    refute has_element?(
             sessions_view,
             "aside button[phx-click='create_session']:not([disabled])"
           )

    {:ok, editor, _} = live(conn, ~p"/agent/agents/#{agent.name}/config")

    SynapsisWeb.ReactFormHelpers.react_form_submit(editor, "agent-config-form", %{
      "agent" => %{"provider" => provider.name, "model" => model.model}
    })

    assert AgentConfigs.get(agent.id).model == model.model

    assert has_element?(
             sessions_view,
             "aside button[phx-click='create_session']:not([disabled])"
           )
  end

  describe "agent sessions page" do
    test "approval remains visible until the runtime acknowledges its resolution", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
      owner = self()

      sink =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:resolve, id, decision}} ->
              send(owner, {:queued_approval, id, decision})

              receive do
                :stop -> :ok
              end
          end
        end)

      id = Ecto.UUID.generate()

      pending = %{
        interaction_id: id,
        run_id: "native-run",
        child: %{name: "/root"},
        request: %{
          tool_name: "synapsis::workspace_memory_get",
          arguments: %{"path" => "MEMORY.md"}
        }
      }

      {_phase, original} = :sys.get_state(worker)

      try do
        :sys.replace_state(worker, fn {phase, data} ->
          {phase, %{data | runtime_pid: sink, runtime_permissions: [pending]}}
        end)

        SessionPersistence.broadcast(session.id, "runtime_permissions", [pending])
        selector = "[data-runtime-permission='#{id}']"
        assert has_element?(view, selector, "synapsis::workspace_memory_get")

        render_click(view, "resolve_runtime_permission", %{
          "interaction-id" => id,
          "decision" => "allow"
        })

        assert_receive {:queued_approval, ^id, true}
        assert has_element?(view, selector)
        SessionPersistence.broadcast(session.id, "runtime_permissions", [])
        refute has_element?(view, selector)
      after
        :sys.replace_state(worker, fn {phase, _data} -> {phase, original} end)
        send(sink, :stop)
      end
    end

    test "remount preserves an idle runtime failure and its reason without replaying the turn", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, message} =
        Synapsis.Message.append(session.id, %{
          role: "user",
          parts: [%Synapsis.Part.Text{content: "why did this fail?"}]
        })

      {:ok, _view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      reason = "Selected tools unavailable or deferred: unavailable-session-tool"
      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "error")
      assert [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

      :ok = await_worker_idle(pid)

      :sys.replace_state(pid, fn {:idle, data} ->
        {:idle,
         %{
           data
           | runtime_history_error:
               Backplane.AgentRuntime.Error.new(:unsupported_capability, reason)
         }}
      end)

      {:ok, remounted, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      socket = chat_socket(remounted)
      assert socket.assigns.session_status == "error"
      assert socket.assigns.flash["error"] == reason
      assert html =~ reason
      assert chat_snapshot(remounted).runtime.phase == "error"
      assert [%{id: message_id, role: "user"}] = chat_snapshot(remounted).messages
      assert message_id == message.id
      assert [%{id: ^message_id, role: "user"}] = Sessions.get_messages(session.id)
    end

    test "session model selector groups configured choices by provider and switches independently from the agent default",
         %{conn: conn} do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "session-models",
          type: "openai",
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, first} =
        Synapsis.Models.create(%{provider_id: provider.id, model: "first", context_window: 8192})

      {:ok, second} =
        Synapsis.Models.create(%{provider_id: provider.id, model: "second", context_window: 4096})

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "catalog-session-agent",
          provider: provider.name,
          model: first.model
        })

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: provider.name,
          model: first.model,
          agent: agent.name
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.name}/sessions/#{session.id}")

      assert %{provider: "session-models", name: "second", context_window: 4096} =
               Enum.find(chat_snapshot(view).metadata.model.choices, &(&1.id == second.id))

      assert %{status: "ok"} = choose_model(view, second.id)
      assert {:ok, updated} = Sessions.get(session.id)
      assert updated.model == second.model
      assert updated.provider == provider.name
      assert AgentConfigs.get_by_name(agent.name).model == first.model
      assert chat_snapshot(view).metadata.model.value == second.id
    end

    test "unavailable current model remains visible and stale choices are rejected", %{conn: conn} do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "unavailable-models",
          type: "openai",
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, model} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "disabled",
          context_window: 4096
        })

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: provider.name,
          model: model.model,
          agent: "main"
        })

      {:ok, _} = Synapsis.Models.update(model, %{enabled: false})
      {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert chat_snapshot(view).metadata.model.value == ""
      assert chat_snapshot(view).metadata.model.label =~ "disabled (unavailable)"

      assert %{status: "error", message: "Selected model is unavailable"} =
               choose_model(view, model.id)

      assert {:ok, unchanged} = Sessions.get(session.id)
      assert unchanged.model == model.model
    end

    test "recovering an empty model selector after provider deletion preserves the session", %{
      conn: conn
    } do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "deleted-model-recovery",
          type: "openai",
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, model} = Synapsis.Models.create(%{provider_id: provider.id, model: "original"})

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: provider.name,
          model: model.model,
          agent: "main"
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert {:ok, _} = Synapsis.Providers.delete(provider.id)
      assert_eventually(fn -> chat_snapshot(view).metadata.model.value == "" end)

      assert %{status: "error", message: "Selected model is unavailable"} =
               choose_model(view, nil)

      assert Process.alive?(view.pid)
      assert {:ok, unchanged} = Sessions.get(session.id)
      assert unchanged.provider == session.provider
      assert unchanged.model == session.model
      assert unchanged.config == session.config
    end

    test "a recreated raw model requires an explicit choice of its new catalog identity", %{
      conn: conn
    } do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "recreated-model",
          type: "openai",
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, original} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "same-name",
          context_window: 4096
        })

      {:ok, session} =
        Sessions.create("__global__", %{
          provider: provider.name,
          model: original.model,
          agent: "main"
        })

      {:ok, _} = Synapsis.Models.delete(original.id)

      {:ok, replacement} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: original.model,
          context_window: 8192
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert chat_snapshot(view).metadata.model.value == ""

      assert chat_snapshot(view).metadata.model.label =~ "same-name (unavailable)"
      assert Enum.any?(chat_snapshot(view).metadata.model.choices, &(&1.id == replacement.id))

      assert %{status: "ok"} = choose_model(view, replacement.id)
      assert {:ok, updated} = Sessions.get(session.id)
      assert updated.config["model_id"] == replacement.id
      assert chat_snapshot(view).metadata.model.value == replacement.id
    end

    test "model selector waits for idle after done and rejects switches while busy", %{
      conn: conn
    } do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "busy-models",
          type: "openai",
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, model} =
        Synapsis.Models.create(%{provider_id: provider.id, model: "target", context_window: 4096})

      {:ok, _} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "current",
          context_window: 8192
        })

      {:ok, session} =
        Sessions.create("__global__", %{provider: provider.name, model: "current", agent: "main"})

      {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      set_worker_running(session)
      send(view.pid, {"session_status", %{status: "streaming"}})
      assert chat_snapshot(view).metadata.model.disabled

      send(view.pid, {"done", %{}})
      assert chat_snapshot(view).metadata.model.disabled

      assert %{
               status: "error",
               message: "Wait for the session to become idle before switching models"
             } =
               choose_model(view, model.id)

      assert {:ok, unchanged} = Sessions.get(session.id)
      assert unchanged.model == "current"

      assert :ok = Worker.cancel(session.id)
      assert_eventually(fn -> not chat_snapshot(view).metadata.model.disabled end)
      assert %{status: "ok"} = choose_model(view, model.id)
      assert {:ok, %{model: "target"}} = Sessions.get(session.id)
    end

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
               "aside button.btn-primary[phx-click='create_session']",
               "New Session"
             )

      view
      |> element(
        "aside button.btn-primary[phx-click='create_session']",
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
      refute has_element?(view, "button[data-confirm]")
      refute has_element?(view, "button[onclick='event.stopPropagation()']")

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
        "#delete-session-modal button[phx-click='cancel_delete_session']",
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
      |> element("#delete-session-modal button[phx-click='delete_session']", "Delete")
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

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      # Personality name appears in the styled span (text-primary/70 class)
      assert html =~ "text-primary/70"
      assert html =~ "Main"
      refute has_element?(view, "[data-session-agent-meta]", "anthropic/test")
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

    test "a run still preparing is active even before its durable status commits", %{
      conn: conn
    } do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)
      # Preparation has not committed the input yet; the last durable status is the
      # previous run's error.
      assert {:ok, _session} = SessionPersistence.update_session_status(session.id, "error")
      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(view.pid, {"session_status", %{status: "streaming"}})

      assert %{runtime: %{phase: "streaming", active: true}, admission: admission} =
               chat_snapshot(view)

      assert %{canSteer: true, sendLabel: "Queue"} = admission
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
      hold_prompt_preparation()
      session = create_image_session()

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      render_hook(view, "send_message", %{"value" => "", "images" => [png_image_payload()]})

      assert_push_event(view, "clear_chat_input", %{})

      assert_receive {:prompt_preparing, discovery}, 5_000
      assert Sessions.get_messages(session.id) == []
      assert [%{id: local_id}] = Enum.filter(chat_snapshot(view).messages, &(&1.role == "user"))
      send(discovery, :continue_prompt)

      assert_eventually(fn ->
        Enum.any?(Sessions.get_messages(session.id), &(&1.role == "user"))
      end)

      assert %Synapsis.Message{
               id: ^local_id,
               parts: [%Synapsis.Part.Image{media_type: "image/png"}]
             } =
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

    test "projects queued prompts into the chat queue and removes them when started", %{
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

      assert [%{id: "queued-prompt-1", text: "queued follow-up", steerable: true}] =
               chat_snapshot(view).metadata.queue

      refute Enum.any?(chat_snapshot(view).messages, &(&1.content == "queued follow-up"))
      assert html =~ "queued follow-up"
      assert Sessions.get_messages(session.id) == []

      send(view.pid, {"input_started", %{id: "queued-prompt-1", kind: "prompt"}})

      html = chat_json(view)

      refute html =~ "queued follow-up"
      assert Sessions.get_messages(session.id) == []
    end

    test "queue actions remove and steer queued prompts through the worker", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      set_worker_running(session)
      assert {:ok, first} = PendingInputStore.append_prompt(session.id, "drop me", [])
      assert {:ok, second} = PendingInputStore.append_prompt(session.id, "steer me", [])

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      assert [first.id, second.id] == Enum.map(chat_snapshot(view).metadata.queue, & &1.id)

      remove = %{"action" => "remove_queued", "input_id" => first.id}

      assert {:reply, %{status: "ok"}, socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(chat_scope(view), remove),
                 chat_socket(view)
               )

      refute Enum.any?(socket.assigns.queued_inputs, &(&1.id == first.id))
      assert [%{id: id}] = PendingInputStore.queued_prompts(session.id)
      assert id == second.id

      steer = %{"action" => "steer_queued", "input_id" => second.id}

      assert {:reply, %{status: "ok"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(chat_scope(view), steer),
                 chat_socket(view)
               )

      # No live runtime in this fixture, so the worker keeps the text as a prompt.
      assert [%{content: "steer me"}] = PendingInputStore.queued_prompts(session.id)

      stale = %{"action" => "remove_queued", "input_id" => Ecto.UUID.generate()}

      assert {:reply, %{status: "error", message: "Message is no longer queued"}, _socket} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.action",
                 Map.merge(chat_scope(view), stale),
                 chat_socket(view)
               )
    end

    test "withdrawn queued prompts leave the chat queue", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(
        view.pid,
        {"input_queued", %{id: "queued-prompt-1", kind: "prompt", content: "withdraw me"}}
      )

      assert [%{id: "queued-prompt-1"}] = chat_snapshot(view).metadata.queue
      send(view.pid, {"input_withdrawn", %{id: "queued-prompt-1"}})
      assert chat_snapshot(view).metadata.queue == []
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

      assert html =~ "same prompt"

      assert ["queued-prompt-1", "queued-prompt-2"] =
               Enum.map(chat_snapshot(view).metadata.queue, & &1.id)

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
      refute has_element?(view, "button[phx-click='retry']")
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
      bypass = Gaoxy.Test.open()
      provider_name = "immediate_chat_#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        Synapsis.Provider.Registry.register(provider_name, %{
          type: "anthropic",
          api_key: "test-key",
          base_url: String.trim_trailing(Gaoxy.Test.url(bypass), "/")
        })

      on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

      Gaoxy.Test.expect_once(bypass, "POST", "/v1/messages", fn conn ->
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
    @tag :tmp_dir
    @tag :functional
    test "a user message can be forked, retried or edited at its own history boundary", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alias Synapsis.Agent.TestSupport.DeterministicProvider
      alias Synapsis.{Message, Part, Providers}

      {:ok, counter} = Agent.start_link(fn -> %{provider_requests: []} end)
      provider = DeterministicProvider.start!(counter: counter, text: "branch reply")

      {:ok, provider_config} =
        Providers.create(%{
          name: provider.name,
          type: "openai_responses",
          base_url: provider.base_url,
          api_key_encrypted: "test-key"
        })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "message-actions",
          provider: provider.name,
          model: "gpt-4o",
          tools: [],
          tool_contract_version: 1,
          config: %{"workspace_path" => tmp_dir}
        })

      {:ok, source} =
        Sessions.create(agent.name, %{
          agent: agent.name,
          provider: provider.name,
          model: agent.model,
          config: %{"subagents" => true, "memory_context" => false}
        })

      on_exit(fn ->
        Sessions.delete(source.id)
        AgentConfigs.delete(agent)
        Providers.delete(provider_config.id)
        DeterministicProvider.stop(provider)
      end)

      [before_prompt, before_reply, selected, later] =
        for {role, text} <- [
              {"user", "earlier prompt"},
              {"assistant", "earlier reply"},
              {"user", "selected prompt 👀"},
              {"assistant", "later reply"}
            ] do
          {:ok, message} =
            Message.append(source.id, %{
              role: role,
              parts: [%Part.Text{content: text}]
            })

          message
        end

      path = ~p"/agent/agents/#{agent.name}/sessions/#{source.id}"
      {:ok, view, _} = live(conn, path)

      assert %{actions: actions} =
               Enum.find(chat_snapshot(view).messages, &(&1.id == selected.id))

      assert Enum.map(actions, & &1.id) == ~w(edit_message fork_message retry_message)

      rejected = %{
        "action" => "fork_message",
        "message_id" => later.id,
        "request_id" => "invalid"
      }

      render_hook(view, "chat.action", Map.merge(chat_scope(view), rejected))
      assert {:ok, [%{id: id}]} = Sessions.list(agent.name)
      assert id == source.id

      branch = fn action, opts ->
        params =
          Map.merge(opts, %{
            "action" => action,
            "message_id" => selected.id,
            "request_id" => action
          })

        render_hook(view, "chat.action", Map.merge(chat_scope(view), params))
        branch_id = view |> assert_patch() |> Path.basename()
        refute branch_id == source.id
        on_exit(fn -> Sessions.delete(branch_id) end)
        branch_id
      end

      fork_id = branch.("fork_message", %{})
      prefix = [before_prompt.parts, before_reply.parts]
      assert Enum.map(Sessions.get_messages(fork_id), & &1.parts) == prefix ++ [selected.parts]
      assert Agent.get(counter, & &1.provider_requests) == []

      for {action, opts, text} <- [
            {"retry_message", %{}, "selected prompt 👀"},
            {"edit_message", %{"text" => "edited prompt"}, "edited prompt"}
          ] do
        render_patch(view, path)
        assert_patch(view, path)
        branch_id = branch.(action, opts)

        assert_eventually(fn ->
          snapshot = Worker.snapshot(branch_id)
          refute snapshot.status == :error, snapshot[:error] || "#{action} failed"
          match?([_, _, %{role: "user"}, %{role: "assistant"}], Sessions.get_messages(branch_id))
        end)

        [first, second, prompt, reply] = Sessions.get_messages(branch_id)
        assert [first.parts, second.parts] == prefix
        assert prompt.parts == [%Part.Text{content: text}]
        assert reply.parts == [%Part.Text{content: "branch reply"}]
      end

      assert length(Agent.get(counter, & &1.provider_requests)) == 2
      assert Sessions.get_messages(source.id) == [before_prompt, before_reply, selected, later]
    end

    for action <- ["edit_message", "retry_message"] do
      @branch_action action
      test "#{action} preserves the selected image through a new turn", %{conn: conn} do
        alias Synapsis.{Image, Message, Part}

        hold_prompt_preparation()
        source = create_image_session()
        on_exit(fn -> Sessions.delete(source.id) end)
        {:ok, [image]} = Image.decode_payloads([png_image_payload()])
        original = %Part.Text{content: "Original caption"}
        {:ok, prompt} = Message.append(source.id, %{role: "user", parts: [original, image]})
        {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{source.id}")

        render_hook(
          view,
          "chat.action",
          Map.merge(chat_scope(view), %{
            "action" => @branch_action,
            "message_id" => prompt.id,
            "request_id" => @branch_action,
            "text" => "Caption"
          })
        )

        id = view |> assert_patch() |> Path.basename()
        refute id == source.id
        on_exit(fn -> Sessions.delete(id) end)

        assert_receive {:prompt_preparing, discovery}, 5_000
        assert Sessions.get_messages(id) == []
        assert [local] = Enum.filter(chat_snapshot(view).messages, &(&1.role == "user"))

        assert local.content ==
                 if(@branch_action == "edit_message", do: "Caption", else: original.content)

        assert Enum.any?(local.metadata.parts, &(&1.type == "image" and &1.data == image.data))

        send(discovery, :continue_prompt)
        assert_receive {:image_provider_request, request}, 5_000
        assert provider_request_has_image?(request)

        assert [%{id: message_id, parts: parts} | _] = Sessions.get_messages(id)
        assert message_id == local.id

        assert_eventually(fn ->
          match?(
            [%{id: ^message_id, metadata: %{tokenCount: count}}] when count > 0,
            Enum.filter(chat_snapshot(view).messages, &(&1.role == "user"))
          )
        end)

        if @branch_action == "edit_message" do
          assert parts == [%Part.Text{content: "Caption"}, image]
        else
          assert parts == [original, image]
        end

        assert Sessions.get_messages(source.id) == [prompt]
      end
    end

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
                %{
                  type: "tool_use",
                  id: "tool-1",
                  status: "complete",
                  result: "file contents"
                },
                %{type: "text"}
              ]
            }
          }
        ]
      })
    end

    test "durable tool results settle their tool card instead of rendering as user turns",
         %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      prompt =
        Synapsis.Message.append(session.id, %{
          role: "user",
          parts: [%Synapsis.Part.Text{content: "list"}]
        })

      assert {:ok, _} = prompt

      {:ok, call} =
        Synapsis.Message.append(session.id, %{
          role: "assistant",
          parts: [
            %Synapsis.Part.ToolUse{tool: "synapsis::ls", tool_use_id: "ok-1", input: %{}},
            %Synapsis.Part.ToolUse{tool: "exec_command", tool_use_id: "bad-1", input: %{}}
          ]
        })

      {:ok, _results} =
        Synapsis.Message.append(session.id, %{
          role: "user",
          parts: [
            %Synapsis.Part.ToolResult{tool_use_id: "ok-1", content: "a.txt"},
            %Synapsis.Part.ToolResult{tool_use_id: "bad-1", content: "denied", is_error: true}
          ]
        })

      {:ok, answer} =
        Synapsis.Message.append(session.id, %{
          role: "assistant",
          parts: [%Synapsis.Part.Text{content: "1 entry"}]
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
      %{messages: messages} = :sys.get_state(view.pid).socket.assigns.react_chat_initial

      call_id = call.id
      answer_id = answer.id

      assert [
               %{role: "user", content: "list"},
               %{id: ^call_id, metadata: %{parts: [ok, bad]}},
               %{id: ^answer_id, content: "1 entry"}
             ] = messages

      assert %{type: "tool_use", status: "complete", result: "a.txt", display: %{}} = ok
      assert %{type: "tool_use", status: "error", result: "denied"} = bad
    end

    test "a new run clears the previous run's error alert", %{conn: conn} do
      {:ok, session} =
        Sessions.create("__global__", %{provider: "anthropic", model: "test", agent: "main"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

      send(view.pid, {"error", %{message: "Provider error (HTTP 500)"}})
      assert render(view) =~ "Provider error (HTTP 500)"

      set_worker_running(session)
      send(view.pid, {"session_status", %{status: "streaming"}})
      refute render(view) =~ "Provider error (HTTP 500)"
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

      assert [
               %{
                 text: "look",
                 steerable: false,
                 attachment: %{src: "data:image/png;base64," <> _}
               }
             ] =
               chat_snapshot(remounted).metadata.queue
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
    @tag :tmp_dir
    test "native Conversation questions render and accept an answer through the chat action", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
      alias Synapsis.Provider.ToolName
      alias Synapsis.Session.Store

      harness =
        SessionHarness.setup_session!(
          tmp_dir: tmp_dir,
          install_provider?: false,
          session_config: %{"subagents" => false, "memory_context" => false}
        )

      on_exit(fn -> SessionHarness.cleanup!(harness) end)
      {:ok, _} = AgentConfigs.update(harness.agent_config, %{tools: ["synapsis::ask_user"]})
      raw = Store.get_value(harness.session.id, "permission")
      :ok = Store.put_value(harness.session.id, "permission", %{raw | mode: :interactive})
      SessionHarness.subscribe!(harness.session.id)

      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Formata.JSON.decode!(body)

        chunks =
          if Enum.any?(request["input"], &(&1["type"] == "function_call_output")) do
            [
              DeterministicProvider.text_chunk("Answer received"),
              DeterministicProvider.finish_chunk("stop")
            ]
          else
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode("synapsis::ask_user"),
                "native-ui-question",
                %{
                  "question" => "Which native approach?",
                  "options" => [%{"label" => "Focused", "description" => "Keep changes small"}]
                }
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
          end

        DeterministicProvider.send_sse(conn, chunks)
      end)

      {:ok, view, _} =
        live(conn, ~p"/agent/agents/#{harness.agent_name}/sessions/#{harness.session.id}")

      assert :ok = Worker.send_message(harness.session.id, "Ask a native question")
      assert_receive {:ask_user, ref, _}, 5_000
      assert_eventually(fn -> chat_snapshot(view).metadata.userQuestions != [] end)

      assert [%{ref: ^ref, question: "Which native approach?"}] =
               chat_snapshot(view).metadata.userQuestions

      assert %{phase: "waiting_for_user", active: true} = chat_snapshot(view).runtime

      render_hook(view, "chat.action", answer_params(view, ref, "Focused", "native-ui-answer"))
      assert_receive {:ask_user_closed, ^ref}, 5_000
      assert_receive {:run_event, %{type: "session.completed"}}, 5_000
      assert_eventually(fn -> chat_snapshot(view).metadata.userQuestions == [] end)

      assert [%Synapsis.Part.ToolResult{content: "Focused", is_error: false}] =
               for(
                 message <- Sessions.get_messages(harness.session.id),
                 part = %Synapsis.Part.ToolResult{} <- message.parts,
                 do: part
               )
    end

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

      refute Formata.JSON.encode!(chat.metadata) =~ "deadline_ms"
      refute Formata.JSON.encode!(chat.metadata) =~ "owner"

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
    test "chat_bubble renders a duskmoon_phoenix chat element for user messages", _ctx do
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

    :ok = await_worker_idle(pid)

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

  # Stands in for the question tool: registers through the Worker's {:ask_user, ...}
  # host protocol and waits for the answer on the session's response topic.
  defp start_user_question(session, options \\ nil) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
    ref = Ecto.UUID.generate()
    parent = self()

    task =
      Task.async(fn ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "ask_user_response:#{session.id}")

        send(
          worker,
          {:ask_user, ref,
           %{
             owner: self(),
             session_id: session.id,
             question: "Which approach?",
             options: options,
             deadline_ms: System.monotonic_time(:millisecond) + 30_000
           }}
        )

        send(parent, {:question_registered, ref})

        receive do
          {:user_response, ^ref, response} -> {:ok, response}
          {:ask_user_cancelled, ^ref} -> {:error, :cancelled}
        after
          30_000 -> {:error, :timeout}
        end
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:question_registered, ^ref}, 1_000
    assert_receive {:ask_user, ^ref, _payload}, 1_000

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
  defp chat_json(view), do: Formata.JSON.encode!(chat_snapshot(view))

  defp choose_model(view, model_id) do
    request_id = Ecto.UUID.generate()
    params = %{"action" => "switch_model", "model_id" => model_id, "request_id" => request_id}
    render_hook(view, "chat.action", Map.merge(chat_scope(view), params))
    chat_snapshot(view).requests[request_id]
  end

  defp chat_scope(view) do
    chat = chat_snapshot(view)
    %{"id" => chat.id, "conversation_id" => chat.conversation_id}
  end

  defp hold_prompt_preparation do
    owner = self()
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "prompt-preparation", "version" => "1"}
            }

          "tools/list" ->
            send(owner, {:prompt_preparing, self()})

            receive do
              :continue_prompt -> %{"tools" => []}
            after
              10_000 -> raise "prompt preparation was not released"
            end

          _notification ->
            %{}
        end

      if request["id"] do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Formata.JSON.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "prompt-preparation-#{System.unique_integer([:positive])}",
               transport: "streamable_http",
               url: Gaoxy.Test.url(fixture, "/mcp")
             })

    agent = AgentConfigs.get_by_name("main")
    selection = %{"default" => "none", "sources" => %{source.id => %{"mode" => "all"}}}

    assert {:ok, _} =
             AgentConfigs.update(agent, %{
               config: Map.put(agent.config || %{}, "mcp_selection", selection)
             })

    on_exit(fn ->
      Synapsis.MCP.stop(source.name)
      Synapsis.MCPConfigs.delete(source)
    end)
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
    bypass = Gaoxy.Test.open()
    provider_name = "image_chat_#{System.unique_integer([:positive])}"
    test_pid = self()

    assert :ok =
             Synapsis.Provider.Registry.register(provider_name, %{
               type: "anthropic",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(bypass), "/")
             })

    on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

    Gaoxy.Test.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:image_provider_request, Formata.JSON.decode!(body)})

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

  # The Worker briefly reconciles its durable input queue after boot.
  defp await_worker_idle(pid, attempts \\ 200) do
    case :sys.get_state(pid) do
      {:idle, _data} ->
        :ok

      _busy when attempts > 0 ->
        Process.sleep(10)
        await_worker_idle(pid, attempts - 1)

      {state, _data} ->
        flunk("session worker stayed #{inspect(state)}")
    end
  end
end
