defmodule SynapsisWeb.AgentLive.ToolsetsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{PluginConfigs, Toolsets}

  setup do
    Synapsis.DataCase.clear_config_store(:plugin)
    Synapsis.DataCase.clear_config_store(:toolset)
    :ok
  end

  defp toolset_by_name(name), do: Enum.find(Toolsets.list(), &(&1.name == name))

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
      |> form("form[phx-submit='save_toolset']", %{
        "toolset" => %{
          "name" => "research-tools",
          "description" => "Search and read"
        },
        "tool_names" => ["file_read", "grep"]
      })
      |> render_submit()

      toolset = toolset_by_name("research-tools")
      assert toolset.tool_names == ["file_read", "grep"]
      assert_redirect(view, ~p"/agent/tools")
    end

    test "groups available tools by category on the toolset form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      assert has_element?(view, "[data-tool-category='filesystem']", "Files")
      assert has_element?(view, "[data-tool-category='filesystem'] input[value='file_read']")
      assert has_element?(view, "[data-tool-category='search']", "Search")
      assert has_element?(view, "[data-tool-category='search'] input[value='grep']")
    end

    test "hides retired tools even if they remain registered in the running registry", %{
      conn: conn
    } do
      retired_tools = ~w(
        workspace_read workspace_write workspace_delete workspace_list workspace_search
        notebook_read notebook_edit
        fetch web_search
      )

      for name <- retired_tools do
        Synapsis.Tool.Registry.register_process(name, self(),
          description: "retired #{name}",
          category: :web
        )
      end

      on_exit(fn ->
        for name <- retired_tools, do: Synapsis.Tool.Registry.unregister(name)
      end)

      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      for name <- retired_tools do
        refute has_element?(view, "input[name='tool_names[]'][value='#{name}']")
      end
    end

    test "select all marks every available tool", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> element("el-dm-button[phx-click='select_all_tools']", "Select all from source")
      |> render_click()

      assert has_element?(view, "input[name='tool_names[]'][value='file_read'][checked]")
      assert has_element?(view, "input[name='tool_names[]'][value='grep'][checked]")
    end

    test "selects MCP source tools from configured servers", %{conn: conn} do
      {:ok, _plugin} =
        PluginConfigs.create(%{
          name: "demo",
          type: "mcp",
          transport: "stdio"
        })

      Synapsis.Tool.Registry.register_process("mcp:demo:search_docs", self(),
        description: "Search docs",
        category: :search
      )

      on_exit(fn -> Synapsis.Tool.Registry.unregister("mcp:demo:search_docs") end)

      {:ok, view, html} = live(conn, ~p"/agent/tools/new")

      assert html =~ "Built in"
      assert html =~ "MCP: demo"
      refute has_element?(view, "input[name='tool_names[]'][value='mcp:demo:search_docs']")

      view
      |> element("[data-testid='tool-source-selector'] el-dm-button", "MCP: demo")
      |> render_click()

      assert has_element?(view, "input[name='tool_names[]'][value='mcp:demo:search_docs']")

      view
      |> element("el-dm-button[phx-click='select_all_tools']", "Select all from source")
      |> render_click()

      assert has_element?(
               view,
               "input[name='tool_names[]'][value='mcp:demo:search_docs'][checked]"
             )

      view
      |> form("form[phx-submit='save_toolset']", %{
        "toolset" => %{
          "name" => "demo-mcp",
          "description" => "Demo MCP tools"
        },
        "tool_names" => ["mcp:demo:search_docs"]
      })
      |> render_submit()

      toolset = toolset_by_name("demo-mcp")
      assert toolset.tool_names == ["mcp:demo:search_docs"]
    end

    test "refreshes MCP tool list when registry changes after page load", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agent/tools/new")
      refute html =~ "MCP: live"
      refute has_element?(view, "input[name='tool_names[]'][value='mcp:live:list_tools']")

      Synapsis.Tool.Registry.register_process("mcp:live:list_tools", self(),
        description: "List live tools",
        category: :search
      )

      on_exit(fn -> Synapsis.Tool.Registry.unregister("mcp:live:list_tools") end)

      assert render(view) =~ "MCP: live"

      view
      |> element("[data-testid='tool-source-selector'] el-dm-button", "MCP: live")
      |> render_click()

      assert has_element?(view, "input[name='tool_names[]'][value='mcp:live:list_tools']")
    end

    test "shows empty MCP source when the configured server has no registered tools", %{
      conn: conn
    } do
      {:ok, _plugin} =
        PluginConfigs.create(%{
          name: "empty",
          type: "mcp",
          transport: "stdio"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> element("[data-testid='tool-source-selector'] el-dm-button", "MCP: empty")
      |> render_click()

      html = render(view)
      assert html =~ "No tools are registered for this source"
      assert html =~ "MCP"
      assert html =~ "Servers"
    end

    test "select all in group marks only that group", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agent/tools/new")

      view
      |> element(
        "[data-tool-category='search'] el-dm-button[phx-click='select_tool_group']",
        "Select all"
      )
      |> render_click()

      assert has_element?(
               view,
               "[data-tool-category='search'] input[name='tool_names[]'][value='grep'][checked]"
             )

      refute has_element?(
               view,
               "[data-tool-category='filesystem'] input[name='tool_names[]'][value='file_read'][checked]"
             )
    end

    test "preserves unavailable MCP tool names when editing", %{conn: conn} do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "mcp-tools",
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
      |> element(~s(el-dm-button[phx-click="delete_toolset"][phx-value-id="#{toolset.id}"]))
      |> render_click()

      refute Toolsets.get(toolset.id)
    end
  end
end
