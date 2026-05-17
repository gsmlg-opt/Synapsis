defmodule SynapsisWeb.AgentLive.ToolsetsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{Repo, Toolset, Toolsets}

  setup do
    Repo.delete_all(Toolset)
    :ok
  end

  describe "toolsets routes" do
    test "lists toolsets and available tools", %{conn: conn} do
      {:ok, _} = Toolsets.create(%{name: "readers", tool_names: ["file_read"]})

      {:ok, view, html} = live(conn, ~p"/agent/tools")

      assert html =~ "Toolsets"
      assert html =~ "readers"
      assert has_element?(view, "aside", "Agents")
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

      toolset = Repo.get_by!(Toolset, name: "research-tools")
      assert toolset.tool_names == ["file_read", "grep"]
      assert_redirect(view, ~p"/agent/tools")
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

      refute Repo.get(Toolset, toolset.id)
    end
  end
end
