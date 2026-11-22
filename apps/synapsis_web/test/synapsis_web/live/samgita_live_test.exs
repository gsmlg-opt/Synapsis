defmodule SynapsisWeb.SamgitaLiveTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.SamgitaConfig
  alias Synapsis.Samgita.{Devices, Inbox}

  @event %{
    "schema_version" => "1.0",
    "event_id" => "evt-l1",
    "delivery_attempt_id" => "att-1",
    "created_at" => "2026-11-12T00:00:00Z",
    "correlation_id" => "c-1",
    "type" => "task.updated",
    "project_ref" => "p-1",
    "payload" => %{}
  }

  setup do
    for device <- Devices.list(), do: SynapsisSamgita.Inbound.disconnect(device["id"])
    Synapsis.DataCase.clear_config_store(:samgita)
    Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
    SynapsisSamgita.disconnect()
    on_exit(fn -> Synapsis.DataCase.clear_coord("coord/samgita/inbox/") end)
    :ok
  end

  test "renders the page and the appbar entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")
    assert has_element?(view, "h1", "Samgita")
    assert has_element?(view, "header.appbar a[href='/samgita']")
  end

  test "saves the Samgita base url", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")
    react_form_submit(view, "samgita-url-form", %{"base_url" => "http://10.100.10.28:4870"})
    assert SamgitaConfig.get().base_url == "http://10.100.10.28:4870"
  end

  test "connecting one configured identity does not register other Agents", %{conn: conn} do
    {:ok, selected} = Synapsis.AgentConfigs.create(%{name: "samgita-selected"})
    {:ok, other} = Synapsis.AgentConfigs.create(%{name: "samgita-other"})
    {:ok, disabled} = Synapsis.AgentConfigs.create(%{name: "samgita-disabled", enabled: false})

    on_exit(fn ->
      for device <- Devices.list(), do: SynapsisSamgita.Inbound.disconnect(device["id"])
      for agent <- [selected, other, disabled], do: Synapsis.AgentConfigs.delete(agent)
    end)

    :ok = SamgitaConfig.put_base_url("http://127.0.0.1:1")
    {:ok, view, _html} = live(conn, ~p"/samgita")
    assert has_element?(view, "#samgita-identity option[value='agent:#{selected.id}']")
    refute has_element?(view, "#samgita-identity option[value='agent:#{disabled.id}']")
    react_form_submit(view, "samgita-identity-form", %{"identity" => "agent:#{disabled.id}"})
    render_async(view)
    assert Devices.list() == []
    react_form_submit(view, "samgita-identity-form", %{"identity" => "agent:#{selected.id}"})
    render_async(view)
    assert [%{"source_id" => id, "source_kind" => "agent"}] = Devices.list()
    assert id == selected.id
  end

  test "remembered identities hide tokens and can be disconnected and forgotten independently", %{
    conn: conn
  } do
    {:ok, first} =
      Devices.select("agent", "first", "First identity", "synapsis", "http://127.0.0.1:1")

    {:ok, second} =
      Devices.select("local_agent", "second", "Second identity", "sigma", "http://127.0.0.1:1")

    {:ok, first_token} = Devices.resolve_token(first["id"])
    {:ok, second_token} = Devices.resolve_token(second["id"])
    {:ok, view, html} = live(conn, ~p"/samgita")
    refute html =~ first_token
    refute html =~ second_token
    assert has_element?(view, "#samgita-device-#{first["id"]}", "First identity")
    assert has_element?(view, "#samgita-device-#{second["id"]}", "Second identity")

    view
    |> element("#samgita-device-#{first["id"]} [phx-value-action='disconnect']")
    |> render_click()

    render_async(view)
    assert {:ok, %{"enabled" => false}} = Devices.get(first["id"])
    assert {:ok, %{"enabled" => true}} = Devices.get(second["id"])

    view
    |> element("#samgita-device-#{first["id"]} [phx-value-action='forget']")
    |> render_click()

    render_async(view)
    assert {:error, :credential_unavailable} = Devices.resolve_token(first["id"])
    assert {:ok, ^second_token} = Devices.resolve_token(second["id"])
    assert has_element?(view, "#samgita-device-#{first["id"]}", "forgotten")
    refute has_element?(view, "#samgita-device-#{first["id"]} [phx-value-action='connect']")
  end

  test "the same event on two devices retains separate processing state", %{conn: conn} do
    {:ok, :new, _} = Inbox.record(@event, "device-first")
    {:ok, :new, _} = Inbox.record(@event, "device-second")
    {:ok, view, _html} = live(conn, ~p"/samgita")
    assert has_element?(view, "#samgita-event-device-first-evt-l1", "pending")
    assert has_element?(view, "#samgita-event-device-second-evt-l1", "pending")

    view
    |> element("#samgita-event-device-first-evt-l1 [phx-click='open_mark_processed']")
    |> render_click()

    react_form_submit(view, "mark-processed-form", %{"note" => "first only"})
    render_async(view)

    assert {:ok, %{"processing_status" => "completed", "note" => "first only"}} =
             Inbox.get("evt-l1", "device-first")

    assert {:ok, %{"processing_status" => "pending"}} = Inbox.get("evt-l1", "device-second")
    assert has_element?(view, "#samgita-event-device-first-evt-l1", "completed")
    assert has_element?(view, "#samgita-event-device-second-evt-l1", "pending")
  end

  test "task view accepts updates only from its selected identity", %{conn: conn} do
    {:ok, device} =
      Devices.select("agent", "selected", "Selected identity", "synapsis", "http://127.0.0.1:1")

    {:ok, _} = Devices.disable(device["id"])
    {:ok, view, _html} = live(conn, ~p"/samgita")
    view |> element("#samgita-device-#{device["id"]} [phx-click='use_device']") |> render_click()
    render_async(view)

    attempt = %{
      id: "a-selected",
      device_id: device["id"],
      project_id: "p-1",
      task_id: "t-1",
      state: "leased",
      version: 1,
      lease_expires_at: nil,
      start_deadline: nil,
      last_error: nil
    }

    SynapsisSamgita.Events.broadcast_attempt(attempt)

    SynapsisSamgita.Events.broadcast_attempt(%{
      attempt
      | id: "a-other",
        device_id: "other-device"
    })

    assert has_element?(view, "#samgita-attempt-a-selected")
    refute has_element?(view, "#samgita-attempt-a-other")
    assert has_element?(view, "#samgita-tasks", "Selected identity")
  end

  test "uncertain execution state is visible only in its device's Task view", %{conn: conn} do
    alias Synapsis.Samgita.Executions

    {:ok, device} =
      Devices.select("agent", "selected", "Selected identity", "synapsis", "http://127.0.0.1:1")

    {:ok, _} = Devices.disable(device["id"])
    event = %{"project_ref" => "project-1", "task_ref" => "task-visible", "event_id" => "event-1"}
    {:ok, :new, entry} = Executions.enqueue(device["id"], event)

    {:ok, _} =
      Executions.update(entry["id"], "recovery_required", %{
        "last_error" => "report_outcome_unconfirmed"
      })

    {:ok, :new, _} = Executions.enqueue("another-device", %{event | "task_ref" => "task-hidden"})
    on_exit(fn -> Synapsis.DataCase.clear_coord("coord/samgita/executions/") end)
    {:ok, view, _} = live(conn, ~p"/samgita")
    view |> element("#samgita-device-#{device["id"]} [phx-click='use_device']") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#samgita-executions [data-task-id='task-visible']",
             "report_outcome_unconfirmed"
           )

    assert has_element?(view, "#samgita-executions", "will not restart automatically")
    refute has_element?(view, "#samgita-executions [data-task-id='task-hidden']")
  end

  test "a generated token is revealed once and never rendered again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")

    render_click(element(view, "[phx-click='rotate_secret'][phx-value-kind='app_server_token']"))
    {:ok, token} = SamgitaConfig.resolve_secret(:app_server_token)
    assert has_element?(view, "[data-role=revealed-secret]", token)

    {:ok, view, html} = live(conn, ~p"/samgita")
    refute html =~ token
    assert has_element?(view, "[data-role=app_server_token-status]", "configured")
  end

  test "lists inbox events and marks one processed", %{conn: conn} do
    {:ok, :new, _} = Inbox.record(@event)
    {:ok, view, _html} = live(conn, ~p"/samgita")

    assert has_element?(view, "#samgita-event-evt-l1", "pending")
    render_click(element(view, "[phx-click='open_mark_processed'][phx-value-id='evt-l1']"))
    react_form_submit(view, "mark-processed-form", %{"note" => "seen"})
    render_async(view)

    assert {:ok, %{"processing_status" => "completed", "note" => "seen"}} = Inbox.get("evt-l1")
    assert render(view) =~ "not reported to Samgita: not_connected"
    assert has_element?(view, "#samgita-event-evt-l1", "completed")
  end

  test "a new delivery appears without reloading", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")
    {:ok, :new, _} = Inbox.record(@event)
    SynapsisSamgita.Events.broadcast_inbox_changed("evt-l1")

    assert render(view) =~ "evt-l1"
  end

  test "tasks require a connection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")
    assert has_element?(view, "#samgita-tasks", "Not connected")
    assert has_element?(view, "[phx-click='connect']")
  end

  test "attempt rows offer the next operator steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/samgita")

    base = %{
      id: "a-1",
      project_id: "p-1",
      task_id: "t-1",
      version: 1,
      lease_expires_at: nil,
      start_deadline: "2026-11-12T00:00:30Z",
      last_error: nil
    }

    refute has_element?(view, "[phx-click='connect'][disabled]")
    SynapsisSamgita.Events.broadcast_attempt(Map.put(base, :state, "leased"))
    assert has_element?(view, "[phx-click='attempt_start'][phx-value-id='a-1']")
    assert has_element?(view, "#samgita-attempt-a-1 [data-role=start-deadline]", "00:00:30")
    assert has_element?(view, "[phx-click='connect'][disabled]")

    SynapsisSamgita.Events.broadcast_attempt(%{base | version: 2} |> Map.put(:state, "running"))
    refute has_element?(view, "[phx-click='attempt_start'][phx-value-id='a-1']")
    refute has_element?(view, "#samgita-attempt-a-1 [data-role=start-deadline]")
    assert has_element?(view, "[phx-click='open_progress'][phx-value-id='a-1']")
    assert has_element?(view, "[phx-click='open_report'][phx-value-id='a-1']")

    SynapsisSamgita.Events.broadcast_attempt(
      %{base | last_error: "stale_version"}
      |> Map.put(:state, "running")
    )

    assert has_element?(view, "#samgita-attempt-a-1", "stale_version")
  end

  test "project coordination exposes ownership, evidence and human review without accepting work",
       %{conn: conn} do
    alias Synapsis.Samgita.Coordination
    event = Map.merge(@event, %{"type" => "manual.triggered", "event_id" => "coordination-ui"})
    {:ok, :new, entry} = Coordination.enqueue("manager-device", event)

    on_exit(fn ->
      Concord.Turso.replace_prefix("coord/samgita/coordination/", [], timeout: 5_000)
    end)

    assert {:ok, _} =
             Coordination.update(entry["id"], fn current ->
               {:ok,
                Map.merge(current, %{
                  "phase" => "awaiting_human_review",
                  "owner_token" => "private-coordinator-token",
                  "children" => %{
                    "one" => %{
                      "task_id" => "task-one",
                      "title" => "Verified change",
                      "assignee_agent_id" => "worker-device",
                      "task_state" => "awaiting_review",
                      "attempt_id" => "attempt-one",
                      "attempt_state" => "succeeded",
                      "result" => %{
                        "summary" => "Verified two checks",
                        "runtime" => %{"session_id" => "session-one"}
                      },
                      "artifact_references" => []
                    },
                    "two" => %{
                      "task_id" => "task-two",
                      "title" => "External result",
                      "assignee_agent_id" => "remote-worker",
                      "task_state" => "awaiting_review",
                      "attempt_id" => "attempt-two",
                      "attempt_state" => "succeeded",
                      "evidence_scope" => "event_and_task_state_only"
                    }
                  }
                })}
             end)

    {:ok, view, html} = live(conn, ~p"/samgita")
    assert has_element?(view, "#samgita-coordination", "Manager device: manager-device")
    assert has_element?(view, "[data-coordination-task='task-one']", "worker-device")
    assert has_element?(view, "[data-coordination-task='task-one']", "Verified two checks")
    assert has_element?(view, "[data-coordination-task='task-one']", "session-one")

    assert has_element?(
             view,
             "[data-coordination-task='task-one']",
             "Human review and acceptance are still required"
           )

    assert has_element?(
             view,
             "[data-coordination-task='task-two']",
             "Only event and Task state are visible"
           )

    refute html =~ "private-coordinator-token"
  end
end
