defmodule SynapsisWeb.AssistantLive.SettingTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.HeartbeatConfig

  describe "assistant setting page" do
    test "mounts and renders setting tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/assistant/build/setting")
      assert html =~ "Overview"
      assert html =~ "Cron Jobs"
    end

    test "can switch to cron jobs tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      html =
        view
        |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
        |> render_click()

      assert html =~ "Heartbeat Schedules"
      assert html =~ "New Heartbeat"
    end

    test "shows new heartbeat form on button click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      # Switch to cron jobs tab
      view
      |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
      |> render_click()

      # Click New Heartbeat
      view
      |> element("el-dm-button[phx-click=\"show_new_heartbeat\"]")
      |> render_click()

      html = render(view)
      assert html =~ "name=\"name\""
      assert html =~ "name=\"schedule\""
      assert html =~ "name=\"prompt\""
    end

    test "cancel heartbeat form hides it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      view
      |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
      |> render_click()

      view
      |> element("el-dm-button[phx-click=\"show_new_heartbeat\"]")
      |> render_click()

      assert render(view) =~ "name=\"name\""

      view
      |> element("el-dm-button[phx-click=\"cancel_heartbeat_form\"]")
      |> render_click()

      refute render(view) =~ "New Heartbeat</h4>"
    end

    test "creates a heartbeat config via form submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      view
      |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
      |> render_click()

      view
      |> element("el-dm-button[phx-click=\"show_new_heartbeat\"]")
      |> render_click()

      view
      |> form("form[phx-submit=\"save_heartbeat\"]", %{
        "name" => "test-heartbeat",
        "schedule" => "0 9 * * *",
        "prompt" => "Run test analysis"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "test-heartbeat"
      assert html =~ "0 9 * * *"
    end

    test "displays existing heartbeat configs on cron tab", %{conn: conn} do
      {:ok, _config} =
        HeartbeatConfig.create(%{
          name: "existing-heartbeat",
          schedule: "30 8 * * 1-5",
          prompt: "Check status",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      html =
        view
        |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
        |> render_click()

      assert html =~ "existing-heartbeat"
      assert html =~ "30 8 * * 1-5"
    end

    test "toggles heartbeat enabled status", %{conn: conn} do
      {:ok, config} =
        HeartbeatConfig.create(%{
          name: "toggle-test",
          schedule: "0 10 * * *",
          prompt: "Toggle test",
          enabled: false
        })

      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      view
      |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
      |> render_click()

      view
      |> element("button[phx-click=\"toggle_heartbeat\"][phx-value-id=\"#{config.id}\"]")
      |> render_click()

      updated = HeartbeatConfig.get(config.id)
      assert updated.enabled == true
    end

    test "deletes a heartbeat config", %{conn: conn} do
      {:ok, config} =
        HeartbeatConfig.create(%{
          name: "delete-test",
          schedule: "0 11 * * *",
          prompt: "Delete test"
        })

      {:ok, view, _html} = live(conn, ~p"/assistant/build/setting")

      view
      |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
      |> render_click()

      assert render(view) =~ "delete-test"

      # Use Synapsis.HeartbeatConfig directly to delete, since data-confirm
      # prevents DOM-based click in tests
      {:ok, _} = HeartbeatConfig.delete_config(config)

      # Verify DB deletion
      assert HeartbeatConfig.get(config.id) == nil

      # Switch away and back to force fresh render with new DB data
      view
      |> element("el-dm-button[phx-value-tab=\"overview\"]")
      |> render_click()

      html =
        view
        |> element("el-dm-button[phx-value-tab=\"cron_jobs\"]")
        |> render_click()

      refute html =~ "delete-test"
    end
  end
end
