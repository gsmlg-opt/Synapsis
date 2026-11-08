defmodule SynapsisWeb.MemorySettingsLive.IndexTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.Config.Store
  alias Synapsis.Memory.Settings

  setup do
    Synapsis.DataCase.clear_config_store(:memory)
    Store.reload(:memory)

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:memory)
      Store.reload(:memory)
    end)

    :ok
  end

  test "settings only configures memory and defaults host off", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings/memory")
    assert html =~ "Workspace Markdown"
    assert html =~ "MEMORY.md"
    assert has_element?(view, "#memory-settings-form")
    assert has_element?(view, "a[href='/agent/memory']")
    refute has_element?(view, "input[name='memory[enabled]'][checked]")
    refute html =~ "New Memory"
    refute html =~ "Checkpoints"
    refute has_element?(view, "#create-memory-form")
    refute File.exists?(Store.file_path(:memory))
  end

  test "saving explicitly enables host configuration and reload preserves it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/memory")

    view
    |> form("#memory-settings-form",
      memory: %{enabled: "true", endpoint: "http://127.0.0.1:4222", agent_id: "synapsis"}
    )
    |> render_submit()

    assert render(view) =~ "Memory settings saved"
    assert :ok = Store.reload(:memory)
    assert Settings.host_enabled?()
    {:ok, reloaded, _} = live(conn, ~p"/settings/memory")
    assert has_element?(reloaded, "input[name='memory[enabled]'][checked]")
  end

  test "mounting and saving settings never calls the configured host", %{conn: conn} do
    server = Gaoxy.Test.open()
    endpoint = String.trim_trailing(Gaoxy.Test.url(server), "/")
    parent = self()

    Gaoxy.Test.stub(server, "POST", "/memory/synapsis/call/recall", fn conn ->
      send(parent, :unexpected_host_request)
      Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)

    assert {:ok, _} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => true,
                 "endpoint" => endpoint,
                 "agent_id" => "synapsis"
               }
             })

    {:ok, view, _} = live(conn, ~p"/settings/memory")

    view
    |> form("#memory-settings-form",
      memory: %{enabled: "true", endpoint: endpoint, agent_id: "synapsis"}
    )
    |> render_submit()

    assert render(view) =~ "Memory settings saved"
    refute_receive :unexpected_host_request
  end

  test "invalid host endpoint is rejected even while disabled", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/memory")

    view
    |> form("#memory-settings-form",
      memory: %{endpoint: "https://example.com", agent_id: "synapsis"}
    )
    |> render_submit()

    assert render(view) =~ "Unable to save memory settings"
    refute Settings.host_enabled?()
  end
end
