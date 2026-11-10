defmodule SynapsisWeb.AgentLive.ToolsetsTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{MCPConfigs, Toolsets}
  alias Synapsis.Config.Store

  defmodule NoopRefresh do
    def refresh, do: %{}
  end

  defmodule BlockingRefresh do
    def refresh do
      send(
        Application.fetch_env!(:synapsis_web, :toolset_refresh_owner),
        {:toolset_refresh_started, self()}
      )

      receive do
        {:release, result} -> result
      after
        5_000 -> %{"source" => {:error, :timeout}}
      end
    end
  end

  setup do
    original = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {NoopRefresh, :refresh, []})

    on_exit(fn ->
      if original,
        do: Application.put_env(:synapsis_core, :mcp_refresh, original),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)

      Application.delete_env(:synapsis_web, :toolset_refresh_owner)
    end)

    Synapsis.DataCase.clear_config_store(:mcp)
    Synapsis.DataCase.clear_config_store(:toolset)
    :ok
  end

  defp toolset_by_name(name), do: Enum.find(Toolsets.list(), &(&1.name == name))

  defp saved_retired_toolset(version, names) do
    id = Ecto.UUID.generate()

    raw = %{
      "id" => id,
      "name" => "saved-retired-#{id}",
      "description" => "Original metadata",
      "tool_names" => names,
      "tool_contract_version" => version,
      "is_builtin" => false,
      "future_setting" => %{"enabled" => true, "order" => ["second", "first"]}
    }

    assert {:ok, ^raw} = Store.put(:toolset, raw)
    raw
  end

  defp browser_tool_names(view, unchecked_name \\ nil) do
    # Native controls are serialized in DOM order by snapshotNativeFields/2.
    # Pass this explicitly so ReactFormHelpers cannot substitute saved initial values.
    view
    |> element("[data-form-id='toolset-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[name='tool_names[]']:not([disabled])")
    |> LazyHTML.to_tree()
    |> Enum.map_reduce(false, fn {"input", attrs, _children}, unchecked? ->
      attrs = Map.new(attrs)

      cond do
        not unchecked? and attrs["type"] == "checkbox" and attrs["value"] == unchecked_name ->
          {[], true}

        attrs["type"] != "checkbox" or Map.has_key?(attrs, "checked") ->
          {[attrs["value"]], unchecked?}

        true ->
          {[], unchecked?}
      end
    end)
    |> elem(0)
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
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
      send(owner, {:display_snapshot, id})
      {:reply, {:ok, %{source_id: id, tools: tools}}, state}
    end

    def handle_call(request, _from, {_id, owner, _tools} = state) do
      send(owner, {:unexpected_mcp_request, request})
      {:reply, {:error, :unexpected_request}, state}
    end
  end

  defp legacy_editor(conn) do
    {:ok, toolset} = Toolsets.create(%{name: "legacy-editor", tool_names: []})
    live(conn, ~p"/agent/tools/#{toolset.id}/edit")
  end

  defp snapshot_source(name, raw_name) do
    {:ok, source} = MCPConfigs.create(%{name: name, transport: "stdio", command: "false"})
    tools = [%{raw_name: raw_name, description: "Snapshot tool", permission_level: :read}]

    start_supervised!(
      Supervisor.child_spec({SnapshotSource, {source.id, self(), tools}}, id: source.id)
    )

    source
  end

  defp toolset_form_mount(view) do
    view
    |> element("[data-form-id='toolset-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("id")
    |> hd()
  end

  defp toolset_initial_values(view) do
    view
    |> element("[data-form-id='toolset-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-initial-values]")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end

  describe "native source metadata mounts" do
    @tag :native_catalog_mount
    test "single source rename remounts the native form and retains the complete draft and saved selection",
         %{conn: conn} do
      source = snapshot_source("single-original-label", "nested::read::docs")
      selected = "mcp::#{source.id}::nested::read::docs"

      raw =
        saved_retired_toolset(1, ["synapsis::file_read", selected, selected, "missing-native"])

      {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"description" => "Retained rename draft"},
        "tool_names" => browser_tool_names(view)
      })

      old_mount = toolset_form_mount(view)
      {:ok, _} = MCPConfigs.update(source, %{name: "single-renamed-label"})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      assert toolset_form_mount(view) != old_mount
      assert has_element?(view, "[phx-value-source='#{source.id}']", "single-renamed-label")
      assert has_element?(view, "input[value='#{selected}'][checked]")
      assert has_element?(view, "input[value='missing-native'][checked]")
      assert toolset_initial_values(view)["toolset"]["description"] == "Retained rename draft"
      assert Enum.sort(browser_tool_names(view)) == Enum.sort(Enum.uniq(raw["tool_names"]))
      react_form_submit(view, "toolset-form", %{"tool_names" => browser_tool_names(view)})
      expected = Map.put(raw, "description", "Retained rename draft")
      assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
      refute_receive {:unexpected_mcp_request, _}
    end

    @tag :native_catalog_mount
    test "empty source addition removal and offline to disabled status remount without losing the native draft",
         %{conn: conn} do
      {:ok, offline} =
        MCPConfigs.create(%{name: "mount-offline", command: "false", enabled: true})

      unavailable = "mcp::#{offline.id}::saved::raw"
      raw = saved_retired_toolset(1, [unavailable, "synapsis::file_read", unavailable])
      {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"description" => "Retained status draft"},
        "tool_names" => browser_tool_names(view)
      })

      initial_mount = toolset_form_mount(view)
      {:ok, empty} = MCPConfigs.create(%{name: "mount-empty", command: "false", enabled: false})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      added_mount = toolset_form_mount(view)
      assert added_mount != initial_mount
      assert has_element?(view, "[phx-value-source='#{empty.id}']", "0 tools")
      assert toolset_initial_values(view)["toolset"]["description"] == "Retained status draft"
      assert has_element?(view, "input[value='#{unavailable}'][checked]")

      {:ok, _} = MCPConfigs.update(offline, %{enabled: false})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      disabled_mount = toolset_form_mount(view)
      assert disabled_mount != added_mount
      assert has_element?(view, "[phx-value-source='#{offline.id}']", "disabled")
      assert toolset_initial_values(view)["toolset"]["description"] == "Retained status draft"
      assert has_element?(view, "input[value='#{unavailable}'][checked]")

      {:ok, _} = MCPConfigs.delete(empty)
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      assert toolset_form_mount(view) != disabled_mount
      refute has_element?(view, "[phx-value-source='#{empty.id}']")
      assert toolset_initial_values(view)["toolset"]["description"] == "Retained status draft"
      assert Enum.sort(browser_tool_names(view)) == Enum.sort(Enum.uniq(raw["tool_names"]))
      react_form_submit(view, "toolset-form", %{"tool_names" => browser_tool_names(view)})
      expected = Map.put(raw, "description", "Retained status draft")
      assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
    end
  end

  describe "native display selection" do
    test "rendering a native static catalog does not automatically refresh every MCP source", %{
      conn: conn
    } do
      Application.put_env(:synapsis_core, :mcp_refresh, {BlockingRefresh, :refresh, []})
      Application.put_env(:synapsis_web, :toolset_refresh_owner, self())
      {:ok, view, _} = live(conn, ~p"/agent/tools/new")
      assert has_element?(view, "input[value='synapsis::read']")
      refute_receive {:toolset_refresh_started, _}
    end

    test "new toolset version is server authored even when the form forges legacy version", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/agent/tools/new")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"name" => "native-created", "tool_contract_version" => "0"},
        "tool_names" => ["send_message", "synapsis::swarm_message"]
      })

      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      render_async(view)

      react_form_submit(view, "toolset-form", %{
        "toolset" => %{"tool_contract_version" => "0"},
        # The browser retains these checked native controls inside phx-update="ignore".
        "tool_names" => ["send_message", "synapsis::swarm_message"]
      })

      saved = toolset_by_name("native-created")
      assert saved.tool_contract_version === 1
      assert saved.tool_names == ["send_message", "synapsis::swarm_message"]
    end

    for version <- [0, 1] do
      test "saved v#{version} keeps exact names, duplicates and version after forged metadata changes",
           %{conn: conn} do
        names = [
          "send_message",
          "file_read",
          "synapsis::file_read",
          "send_message",
          "mcp::#{Ecto.UUID.generate()}::raw::nested"
        ]

        raw = saved_retired_toolset(unquote(version), names)
        {:ok, view, html} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

        if unquote(version) == 0 do
          assert html =~ "Legacy selection"
          assert html =~ "migration"
        else
          assert has_element?(
                   view,
                   "[data-tool-category='unavailable'] input[value='file_read'][checked]"
                 )

          refute has_element?(
                   view,
                   "[data-tool-category='unavailable'] input[value='send_message']"
                 )
        end

        react_form_change(view, "toolset-form", %{
          "toolset" => %{
            "description" => "Native draft",
            "tool_contract_version" => to_string(1 - unquote(version))
          },
          "tool_names" => browser_tool_names(view)
        })

        view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
        render_async(view)

        react_form_submit(view, "toolset-form", %{
          "toolset" => %{"tool_contract_version" => to_string(1 - unquote(version))},
          "tool_names" => browser_tool_names(view)
        })

        expected = Map.put(raw, "description", "Native draft")
        assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
      end
    end

    test "native source identity uses config UUID and complete raw suffix across duplicate names and rename",
         %{conn: conn} do
      raw_name = "namespace::search::docs"
      first = snapshot_source("same-label", raw_name)
      second = snapshot_source("same-label", raw_name)
      first_name = "mcp::#{first.id}::#{raw_name}"
      second_name = "mcp::#{second.id}::#{raw_name}"
      raw = saved_retired_toolset(1, [first_name])
      {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")

      for source <- [first, second] do
        assert has_element?(
                 view,
                 "[data-testid='tool-source-selector'] [phx-value-source='#{source.id}']",
                 "same-label"
               )
      end

      view
      |> element("[phx-click='select_tool_source'][phx-value-source='#{first.id}']")
      |> render_click()

      assert has_element?(view, "input[type='checkbox'][value='#{first_name}']")
      refute has_element?(view, "input[type='checkbox'][value='#{second_name}']")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"name" => "uuid-native"},
        "tool_names" => [first_name]
      })

      {:ok, _} = MCPConfigs.update(first, %{name: "renamed-label"})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      render_async(view)
      assert has_element?(view, "[phx-value-source='#{first.id}']", "renamed-label")
      assert has_element?(view, "input[value='#{first_name}'][checked]")
      react_form_submit(view, "toolset-form", %{"tool_names" => browser_tool_names(view)})
      assert toolset_by_name("uuid-native").tool_names == [first_name]
      assert_receive {:display_snapshot, _}
      refute_receive {:unexpected_mcp_request, _}
    end

    test "disabled and unavailable native sources remain visible with counts and removable saved selections",
         %{conn: conn} do
      {:ok, disabled} =
        MCPConfigs.create(%{name: "disabled-native", command: "false", enabled: false})

      {:ok, offline} =
        MCPConfigs.create(%{name: "offline-native", command: "false", enabled: true})

      unavailable = "mcp::#{offline.id}::gone::raw"
      raw = saved_retired_toolset(1, [unavailable, "synapsis::file_read", unavailable])
      {:ok, view, _} = live(conn, ~p"/agent/tools/#{raw["id"]}/edit")
      assert has_element?(view, "[phx-value-source='#{disabled.id}']", "disabled")
      assert has_element?(view, "[phx-value-source='#{offline.id}']", "unavailable")
      assert has_element?(view, "[phx-value-source='#{disabled.id}']", "0")

      assert has_element?(
               view,
               "[data-tool-category='unavailable'] input[value='#{unavailable}'][checked]"
             )

      react_form_submit(view, "toolset-form", %{
        "tool_names" => browser_tool_names(view, unavailable)
      })

      expected = Map.put(raw, "tool_names", ["synapsis::file_read"])
      assert {:ok, ^expected} = Store.get(:toolset, raw["id"])
    end
  end

  describe "toolsets routes" do
    test "lists toolsets and available tools", %{conn: conn} do
      {:ok, _} = Toolsets.create(%{name: "readers", tool_names: ["file_read"]})

      {:ok, view, html} = live(conn, ~p"/agent/tools")

      assert html =~ "Toolsets"
      assert html =~ "readers"
      assert has_element?(view, "aside", "Agents")
      assert has_element?(view, "aside .app-left-menu a.app-left-menu-item", "Agents")
      assert html =~ "file_read"
    end

    test "creates a toolset from selected tool names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> react_form_submit("toolset-form", %{
        "toolset" => %{
          "name" => "research-tools",
          "description" => "Search and read"
        },
        "tool_names" => ["synapsis::file_read", "synapsis::grep"]
      })

      toolset = toolset_by_name("research-tools")
      assert toolset.tool_names == ["synapsis::file_read", "synapsis::grep"]
      assert toolset.tool_contract_version === 1
      assert_redirect(view, ~p"/agent/tools")
    end

    test "groups available tools by category on the toolset form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agent/tools/new")

      assert has_element?(view, "[data-form-id='toolset-form']")
      assert has_element?(view, "[data-tool-category='filesystem']", "Files")

      assert has_element?(
               view,
               "[data-tool-category='filesystem'] input[value='synapsis::read']"
             )

      assert has_element?(view, "[data-tool-category='web']", "Web")
      assert has_element?(view, "[data-tool-category='web'] input[value='web::fetch']")
      assert_unique_form_ids(html)
    end

    test "select all marks every available tool", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> element("el-dm-button[phx-click='select_all_tools']", "Select all from source")
      |> render_click()

      assert has_element?(
               view,
               "input[name='tool_names[]'][value='synapsis::read'][checked]"
             )

      assert has_element?(view, "input[name='tool_names[]'][value='web::fetch'][checked]")
    end

    test "group selection does not add disabled computer tools", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      react_form_change(view, "toolset-form", %{
        "toolset" => %{"name" => "available-group"},
        "tool_names" => ["synapsis::file_read"]
      })

      render_click(view, "select_tool_group", %{"category" => "computer"})
      react_form_submit(view, "toolset-form", %{})

      assert toolset_by_name("available-group").tool_names == ["synapsis::file_read"]
    end

    test "shows empty MCP source when the configured server has no registered tools", %{
      conn: conn
    } do
      {:ok, _plugin} =
        MCPConfigs.create(%{
          name: "empty",
          transport: "stdio",
          command: "npx"
        })

      {:ok, view, _html} = legacy_editor(conn)

      view
      |> element("[data-testid='tool-source-selector'] el-dm-button", "MCP: empty")
      |> render_click()

      html = render(view)
      assert html =~ "No tools are present in the local MCP snapshot"
      assert html =~ "MCP"
      assert html =~ "Servers"
    end

    test "select all in group marks only that group", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> element(
        "[data-tool-category='web'] el-dm-button[phx-click='select_tool_group']",
        "Select all"
      )
      |> render_click()

      assert has_element?(
               view,
               "[data-tool-category='web'] input[name='tool_names[]'][value='web::fetch'][checked]"
             )

      refute has_element?(
               view,
               "[data-tool-category='filesystem'] input[name='tool_names[]'][value='synapsis::read'][checked]"
             )
    end

    test "preserves unavailable MCP tool names when editing", %{conn: conn} do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "mcp-tools",
          tool_contract_version: 1,
          tool_names: ["mcp:demo:search_docs"]
        })

      {:ok, _view, html} = live(conn, ~p"/agent/tools/#{toolset.id}/edit")

      assert html =~ "mcp:demo:search_docs"
      assert html =~ "Unavailable"
    end

    test "removes a custom toolset", %{conn: conn} do
      {:ok, toolset} = Toolsets.create(%{name: "temporary"})

      {:ok, view, _html} = live(conn, ~p"/agent/tools")

      view
      |> element(~s(button[phx-click="delete_toolset"][phx-value-id="#{toolset.id}"]))
      |> render_click()

      refute Toolsets.get(toolset.id)
    end
  end
end
