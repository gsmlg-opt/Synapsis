defmodule SynapsisWeb.SamgitaLiveTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.SamgitaConfig
  alias Synapsis.Samgita.Inbox

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
end
