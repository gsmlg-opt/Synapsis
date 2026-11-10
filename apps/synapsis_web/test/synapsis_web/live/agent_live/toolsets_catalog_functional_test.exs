defmodule SynapsisWeb.AgentLive.ToolsetsCatalogFunctionalTest do
  use SynapsisWeb.ConnCase
  @moduletag :functional

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{MCPConfigs, Toolsets}
  alias Synapsis.Agent.Tools.DisplayCatalog
  alias Synapsis.Config.Store

  defmodule LocalRefresh do
    def refresh do
      send(Application.fetch_env!(:synapsis_web, :catalog_test_owner), :discovery_refresh)
      %{}
    end
  end

  defmodule SnapshotSource do
    use GenServer

    def start_link({id, owner, tools}) do
      GenServer.start_link(__MODULE__, {id, owner, tools},
        name: {:via, Registry, {Synapsis.MCP.Registry, {:config_id, id}}}
      )
    end

    def init(state), do: {:ok, state}

    def handle_call(:runtime_snapshot, _from, {id, owner, tools} = state) do
      send(owner, {:local_snapshot, id})
      {:reply, {:ok, %{source_id: id, tools: tools}}, state}
    end

    def handle_call(:catalog, _from, {id, owner, _tools} = state) do
      send(owner, {:legacy_catalog, id})
      {:reply, {:error, :unavailable}, state}
    end
  end

  setup do
    assert String.contains?(Store.config_dir(), "config_store_test")
    assert System.get_env("MIX_TEST_PARTITION") not in [nil, ""]
    Synapsis.DataCase.clear_config_store(:mcp)
    Synapsis.DataCase.clear_config_store(:toolset)
    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {LocalRefresh, :refresh, []})
    Application.put_env(:synapsis_web, :catalog_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)

      Application.delete_env(:synapsis_web, :catalog_test_owner)
    end)

    :ok
  end

  test "every native catalog entry including Media is selectable and saves as v1", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/tools/new")

    for tool <- DisplayCatalog.list() do
      assert has_element?(
               view,
               "[data-tool-category='#{tool.category}'] input[name='tool_names[]'][value='#{tool.name}']:not([disabled])"
             )

      assert has_element?(view, "[data-tool-category='#{tool.category}']", tool.description)
    end

    render_click(view, "select_tool_group", %{"category" => "media"})
    assert Enum.sort(browser_names(view)) == ["synapsis::pdf", "synapsis::tts"]
    render_click(view, "select_all_tools", %{})
    assert Enum.sort(browser_names(view)) == Enum.sort(Enum.map(DisplayCatalog.list(), & &1.name))

    react_form_submit(view, "toolset-form", %{
      "toolset" => %{"name" => "Complete native"},
      "tool_names" => browser_names(view)
    })

    assert_redirect(view, ~p"/agent/tools")
    saved = Enum.find(Toolsets.list(), &(&1.name == "Complete native"))
    assert saved.tool_contract_version == 1
    assert Enum.sort(saved.tool_names) == Enum.sort(Enum.map(DisplayCatalog.list(), & &1.name))
    assert {:ok, _, _} = live(conn, ~p"/agent/tools/#{saved.id}/edit")
  end

  test "legacy preview shows the complete native catalog beside distinct removable saved names",
       %{conn: conn} do
    raw =
      legacy(["send_message", "fetch", "send_message", "unknown-old", "mcp:historical:missing"])

    {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

    assert has_element?(view, "[data-testid='native-catalog-preview']", "read-only")
    assert has_element?(view, "a[href='/agent/tools/new']", "New native Toolset")

    for tool <- DisplayCatalog.list() do
      assert has_element?(
               view,
               "[data-testid='native-catalog-preview'] [data-tool-category='#{tool.category}']",
               tool.name
             )

      assert has_element?(view, "[data-testid='native-catalog-preview']", tool.description)
    end

    assert controls(
             view,
             "[data-testid='native-catalog-preview'] input[name='tool_names[]']:not([disabled])"
           ) == []

    assert controls(view, "[phx-click='select_all_tools'], [phx-click='select_tool_group']") == []
    assert Enum.sort(browser_names(view)) == Enum.sort(Enum.uniq(raw["tool_names"]))

    for name <- Enum.uniq(raw["tool_names"]) do
      assert length(
               controls(
                 view,
                 "[data-tool-category='legacy-selection'] input[value='#{name}'][checked]"
               )
             ) == 1
    end
  end

  test "legacy metadata save preserves raw order duplicates version and unknown fields through tabs and refresh",
       %{conn: conn} do
    source = snapshot_source("local-legacy", "read::nested::docs")

    raw =
      legacy([
        "mcp:historical:missing",
        "send_message",
        "fetch",
        "send_message",
        "unknown-old",
        "fetch"
      ])

    {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
    assert has_element?(view, "[data-tool-category='media']", "synapsis::tts")

    react_form_change(view, "toolset-form", %{
      "toolset" => %{"name" => "Edited legacy", "description" => "Retained draft"},
      "tool_names" => browser_names(view)
    })

    render_click(view, "select_tool_source", %{"source" => source.id})

    assert has_element?(
             view,
             "[data-testid='native-catalog-preview']",
             "mcp::#{source.id}::read::nested::docs"
           )

    assert Enum.sort(browser_names(view)) == Enum.sort(Enum.uniq(raw["tool_names"]))
    refresh(view)
    render_click(view, "select_tool_source", %{"source" => "built-in"})
    assert initial_values(view)["toolset"]["description"] == "Retained draft"
    react_form_submit(view, "toolset-form", %{"tool_names" => browser_names(view)})
    assert_redirect(view, ~p"/agent/tools")
    expected = Map.merge(raw, %{"name" => "Edited legacy", "description" => "Retained draft"})
    assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
    {:ok, reopened, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
    assert initial_values(reopened)["tool_names"] == raw["tool_names"]
    assert_receive {:local_snapshot, _}
    refute_receive :discovery_refresh
    refute_receive {:legacy_catalog, _}
  end

  test "explicitly unchecking a saved legacy name removes all its occurrences and retains the others",
       %{conn: conn} do
    raw =
      legacy(["fetch", "send_message", "unknown-old", "send_message", "fetch", "mcp:gone:keep"])

    {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

    react_form_change(view, "toolset-form", %{"tool_names" => browser_names(view, "send_message")})

    refresh(view)
    react_form_submit(view, "toolset-form", %{"tool_names" => browser_names(view)})
    expected = Map.put(raw, "tool_names", Enum.reject(raw["tool_names"], &(&1 == "send_message")))
    assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
    {:ok, reopened, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
    assert initial_values(reopened)["tool_names"] == expected["tool_names"]
  end

  test "duplicate MCP labels retain UUID and complete raw suffix identity during native save", %{
    conn: conn
  } do
    first = snapshot_source("same-label", "read::nested::docs")
    second = snapshot_source("same-label", "read::nested::docs")
    {:ok, view, _} = live(conn, ~p"/agent/tools/new")
    assert has_element?(view, "[phx-value-source='#{first.id}']", "same-label")
    assert has_element?(view, "[phx-value-source='#{second.id}']", "same-label")
    render_click(view, "select_tool_source", %{"source" => first.id})
    render_click(view, "select_all_tools", %{})
    render_click(view, "select_tool_source", %{"source" => second.id})
    render_click(view, "select_tool_group", %{"category" => "uncategorized"})
    expected = Enum.map([first, second], &"mcp::#{&1.id}::read::nested::docs")
    assert Enum.sort(browser_names(view)) == Enum.sort(expected)

    react_form_submit(view, "toolset-form", %{
      "toolset" => %{"name" => "UUID selection"},
      "tool_names" => browser_names(view)
    })

    saved = Enum.find(Toolsets.list(), &(&1.name == "UUID selection"))
    assert saved.tool_names == expected
    {:ok, reopened, _} = live(conn, ~p"/agent/tools/#{saved.id}/edit")
    assert has_element?(reopened, "input[value='#{hd(expected)}'][checked]")
  end

  test "local source metadata events remount both forms without losing draft or ordered selections",
       %{conn: conn} do
    for version <- [0, 1] do
      source = snapshot_source("original-#{version}", "read::nested")
      selected = "mcp::#{source.id}::read::nested"
      raw = legacy([selected, "send_message", selected, "unknown-old"], version)
      {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
      assert has_element?(view, "[phx-value-source='#{source.id}'][variant='primary']")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"description" => "Draft #{version}"},
        "tool_names" => browser_names(view)
      })

      old_mount = mount_id(view)
      assert {:ok, _} = MCPConfigs.update(source, %{name: "renamed-#{version}"})

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "tool_registry",
        {:mcp_source_catalog_changed, %{source_id: source.id}}
      )

      render(view)
      assert mount_id(view) != old_mount
      assert has_element?(view, "[phx-value-source='#{source.id}']", "renamed-#{version}")
      assert initial_values(view)["toolset"]["description"] == "Draft #{version}"
      assert initial_values(view)["tool_names"] == raw["tool_names"]
      react_form_submit(view, "toolset-form", %{"tool_names" => browser_names(view)})
      expected = Map.put(raw, "description", "Draft #{version}")
      assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
    end

    refute_receive :discovery_refresh
    refute_receive {:legacy_catalog, _}
  end

  test "offline disabled and empty local sources stay visible across structural changes", %{
    conn: conn
  } do
    {:ok, offline} = MCPConfigs.create(%{name: "offline", command: "false"})
    empty = snapshot_source("empty", nil)
    raw = legacy(["mcp::#{offline.id}::saved", "unknown-old"], 1)
    {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
    assert has_element?(view, "[phx-value-source='#{offline.id}']", "0 tools · unavailable")
    assert has_element?(view, "[phx-value-source='#{empty.id}']", "0 tools · available")

    react_form_change(view, "toolset-form", %{
      "toolset" => %{"description" => "Source draft"},
      "tool_names" => browser_names(view)
    })

    old_mount = mount_id(view)
    {:ok, disabled} = MCPConfigs.create(%{name: "disabled", command: "false", enabled: false})
    refresh(view)
    assert mount_id(view) != old_mount
    assert has_element?(view, "[phx-value-source='#{disabled.id}']", "0 tools · disabled")
    added_mount = mount_id(view)
    {:ok, _} = MCPConfigs.update(offline, %{enabled: false})
    refresh(view)
    assert mount_id(view) != added_mount
    assert has_element?(view, "[phx-value-source='#{offline.id}']", "disabled")
    assert {:ok, _} = MCPConfigs.delete(empty)
    refresh(view)
    assert controls(view, "[phx-value-source='#{empty.id}']") == []
    assert initial_values(view)["toolset"]["description"] == "Source draft"
    react_form_submit(view, "toolset-form", %{"tool_names" => browser_names(view)})
    expected = Map.put(raw, "description", "Source draft")
    assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
  end

  test "a historical record with omitted contract version keeps its raw shape on metadata save",
       %{conn: conn} do
    raw = legacy(["send_message", "fetch", "send_message"])
    raw = Map.delete(raw, "tool_contract_version")
    assert {:ok, ^raw} = Store.put(:toolset, raw)
    {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
    assert has_element?(view, "[data-testid='native-catalog-preview']", "synapsis::pdf")

    react_form_submit(view, "toolset-form", %{
      "toolset" => %{"description" => "Historical metadata"},
      "tool_names" => browser_names(view)
    })

    expected = Map.put(raw, "description", "Historical metadata")
    assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
  end

  test "ordinary obsolete Registry notifications leave the local catalog form intact", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/agent/tools/new")
    old_mount = mount_id(view)
    send(view.pid, {:tool_registry_changed, %{}})
    render(view)
    assert mount_id(view) == old_mount
    assert has_element?(view, "[data-tool-category='media']", "synapsis::pdf")
  end

  defp legacy(names, version \\ 0) do
    raw = %{
      "id" => Ecto.UUID.generate(),
      "name" => "Saved selection",
      "description" => "Original metadata",
      "tool_names" => names,
      "tool_contract_version" => version,
      "is_builtin" => false,
      "future_option" => %{"order" => ["second", "first"]}
    }

    assert {:ok, ^raw} = Store.put(:toolset, raw)
    raw
  end

  defp snapshot_source(name, raw_name) do
    {:ok, source} = MCPConfigs.create(%{name: name, command: "false"})
    tools = if raw_name, do: [%{raw_name: raw_name, description: "Local snapshot tool"}], else: []

    start_supervised!(
      Supervisor.child_spec({SnapshotSource, {source.id, self(), tools}}, id: source.id)
    )

    source
  end

  defp refresh(view),
    do: view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()

  defp controls(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.to_tree()
  end

  defp browser_names(view, unchecked \\ nil) do
    controls(view, "input[name='tool_names[]']:not([disabled])")
    |> Enum.flat_map(fn {"input", attrs, _} ->
      attrs = Map.new(attrs)

      if attrs["value"] != unchecked and
           (attrs["type"] != "checkbox" or Map.has_key?(attrs, "checked")),
         do: [attrs["value"]],
         else: []
    end)
  end

  defp initial_values(view) do
    view
    |> element("[data-form-id='toolset-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-initial-values]")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end

  defp mount_id(view) do
    view
    |> element("[data-form-id='toolset-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("id")
    |> hd()
  end
end
