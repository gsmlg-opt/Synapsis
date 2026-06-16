defmodule SynapsisWeb.MCPLive.IndexTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.MCPConfigs

  setup do
    Synapsis.DataCase.clear_config_store(:mcp)
    :ok
  end

  # Minimal stub registered in Synapsis.MCP.Registry so Synapsis.MCP.list/0
  # reports the server as running, without standing up a real anubis client.
  defmodule FakeMCPServer do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)

      GenServer.start_link(__MODULE__, :ok, name: {:via, Registry, {Synapsis.MCP.Registry, name}})
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  defp create_mcp_config(attrs) do
    {:ok, config} = MCPConfigs.create(Map.merge(%{transport: "stdio"}, attrs))
    config
  end

  describe "MCP servers page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "MCP Servers"
      assert has_element?(view, "h1", "MCP Servers")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Settings"
    end

    test "shows Add MCP Server button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Add MCP Server"
    end

    test "shows new server form on /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "New MCP Server"
      assert html =~ "Command"
      assert html =~ "Arguments (one per line)"
      assert html =~ "Environment Variables"
    end

    test "new form switches HTTP transport fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> form(~s(form[phx-submit="create_config"]), %{
          "name" => "http-test",
          "transport" => "streamable_http"
        })
        |> render_change()

      assert html =~ "URL"
      assert html =~ "Headers (Name: Value, one per line)"
      assert html =~ ~s(name="headers")
      refute html =~ "Command"
      refute html =~ "Arguments (one per line)"
      refute html =~ "Environment Variables"
    end

    test "creates MCP config from stdio form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> form(~s(form[phx-submit="create_config"]), %{
        "name" => "custom-test",
        "command" => "npx -y test-server",
        "transport" => "stdio"
      })
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"
    end

    test "creates HTTP MCP config from form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> form(~s(form[phx-submit="create_config"]), %{
        "name" => "http-test",
        "transport" => "streamable_http"
      })
      |> render_change()

      view
      |> form(~s(form[phx-submit="create_config"]), %{
        "name" => "http-test",
        "transport" => "streamable_http",
        "url" => "http://localhost:7331/mcp",
        "headers" => "Authorization: Bearer test-token\nX-Workspace: docs\ninvalid"
      })
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"

      config = MCPConfigs.get_by_name("http-test")
      assert config.transport == "streamable_http"
      assert config.url == "http://localhost:7331/mcp"
      assert config.command in [nil, ""]
      assert config.args == []
      assert config.env == %{}

      assert config.headers == %{
               "Authorization" => "Bearer test-token",
               "X-Workspace" => "docs"
             }
    end

    test "deletes MCP config", %{conn: conn} do
      config = create_mcp_config(%{name: "deletable", command: "test-cmd"})

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "deletable"

      view
      |> element(~s(el-dm-button[phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "deletable"
    end

    test "toggle_enabled flips enabled", %{conn: conn} do
      config = create_mcp_config(%{name: "toggleable", command: "test", enabled: false})

      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      # dm_switch renders phx-click on an <input>, not a <button>
      view
      |> element(~s(input[phx-click="toggle_enabled"][phx-value-id="#{config.id}"]))
      |> render_click()

      updated = MCPConfigs.get(config.id)
      assert updated.enabled == true
    end

    test "displays env var count for config with env", %{conn: conn} do
      create_mcp_config(%{
        name: "env-server",
        command: "test",
        env: %{"KEY1" => "val1", "KEY2" => "val2"}
      })

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "2 env var(s)"
    end

    test "displays args for config with args", %{conn: conn} do
      create_mcp_config(%{
        name: "args-server",
        command: "npx",
        args: ["-y", "@test/server"]
      })

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "-y @test/server"
    end

    test "running server shows tools modal trigger from registry", %{conn: conn} do
      config = create_mcp_config(%{name: "tools-server", command: "test"})

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Synapsis.MCP.DynamicSupervisor,
          %{
            id: {:fake, config.name},
            start: {FakeMCPServer, :start_link, [[name: config.name]]},
            restart: :temporary
          }
        )

      tool_name = "mcp:#{config.name}:search_docs"

      Synapsis.Tool.Registry.register_process(tool_name, self(),
        description: "Search docs",
        parameters: %{},
        plugin: :mcp
      )

      on_exit(fn -> Synapsis.Tool.Registry.unregister(tool_name) end)

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")

      assert html =~ "Running"
      assert html =~ "1 tool(s)"
      assert html =~ ".show()"
      refute html =~ "showModal()"
    end

    test "lists multiple MCP configs", %{conn: conn} do
      create_mcp_config(%{name: "server-a", command: "cmd-a"})
      create_mcp_config(%{name: "server-b", command: "cmd-b"})

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "server-a"
      assert html =~ "server-b"
    end

    test "delete_config with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      html = render_hook(view, "delete_config", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "empty state message shown when no configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "No MCP servers configured"
    end
  end
end
