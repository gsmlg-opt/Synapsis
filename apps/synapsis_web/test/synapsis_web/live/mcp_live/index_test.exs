defmodule SynapsisWeb.MCPLive.IndexTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.PluginConfigs

  setup do
    Synapsis.DataCase.clear_config_store(:plugin)
    :ok
  end

  defmodule FakeMCPPlugin do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      state = Keyword.fetch!(opts, :state)

      GenServer.start_link(__MODULE__, state,
        name: {:via, Registry, {SynapsisPlugin.Registry, name}}
      )
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  defp create_mcp_config(attrs) do
    {:ok, config} = PluginConfigs.create(Map.merge(%{type: "mcp", transport: "stdio"}, attrs))
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

    test "shows preset selector on /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Select an MCP Server"
      assert html =~ "filesystem"
      assert html =~ "github"
      assert html =~ "playwright"
      assert html =~ "memory"
    end

    test "shows custom option in preset selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Custom MCP Server"
    end

    test "selecting a preset shows form with pre-filled command", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s([phx-click="select_preset"][phx-value-name="filesystem"]))
        |> render_click()

      assert html =~ "npx"
      assert html =~ "Add MCP Server"
    end

    test "selecting custom shows editable form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s([phx-click="select_custom"]))
        |> render_click()

      assert html =~ "New Custom MCP Server"
      assert html =~ "HTTP"
      assert html =~ "Command"
      assert html =~ "Arguments (one per line)"
      assert html =~ "Environment Variables"
      refute html =~ ~s(name="url")
      refute html =~ "Headers"
    end

    test "custom form switches HTTP transport fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s([phx-click="select_custom"]))
      |> render_click()

      html =
        view
        |> form(~s(form[phx-submit="create_config"]), %{
          "name" => "http-test",
          "transport" => "http"
        })
        |> render_change()

      assert html =~ "URL"
      assert html =~ "Headers (Name: Value, one per line)"
      assert html =~ ~s(name="headers")
      refute html =~ "Command"
      refute html =~ "Arguments (one per line)"
      refute html =~ "Environment Variables"
    end

    test "creates MCP config from preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s([phx-click="select_preset"][phx-value-name="memory"]))
      |> render_click()

      view
      |> form(~s(form[phx-submit="create_config"]))
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"
    end

    test "creates MCP config from custom form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s([phx-click="select_custom"]))
      |> render_click()

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

    test "creates HTTP MCP config from custom form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s([phx-click="select_custom"]))
      |> render_click()

      view
      |> form(~s(form[phx-submit="create_config"]), %{
        "name" => "http-test",
        "transport" => "http"
      })
      |> render_change()

      view
      |> form(~s(form[phx-submit="create_config"]), %{
        "name" => "http-test",
        "transport" => "http",
        "url" => "http://localhost:7331/mcp",
        "headers" => "Authorization: Bearer test-token\nX-Workspace: docs\ninvalid"
      })
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"

      config = PluginConfigs.get_by_name_type("http-test", "mcp")
      assert config.transport == "http"
      assert config.url == "http://localhost:7331/mcp"
      assert config.command in [nil, ""]
      assert config.args == []
      assert config.env == %{}

      assert config.settings == %{
               "headers" => %{
                 "Authorization" => "Bearer test-token",
                 "X-Workspace" => "docs"
               }
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

    test "toggle_enabled switches auto_start", %{conn: conn} do
      config = create_mcp_config(%{name: "toggleable", command: "test", auto_start: false})

      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      # dm_switch renders phx-click on an <input>, not a <button>
      view
      |> element(~s(input[phx-click="toggle_enabled"][phx-value-id="#{config.id}"]))
      |> render_click()

      # Verify the config was toggled in the DB
      updated = PluginConfigs.get(config.id)
      assert updated.auto_start == true
    end

    test "already-added servers are indicated in preset selector", %{conn: conn} do
      create_mcp_config(%{name: "filesystem", command: "npx"})

      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Already configured"
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

    test "tools modal trigger uses DuskMoon dialog show API", %{conn: conn} do
      config = create_mcp_config(%{name: "tools-server", command: "test"})

      start_supervised!(
        {FakeMCPPlugin,
         name: config.name,
         state: %SynapsisPlugin.MCP{
           initialized: true,
           tools: [
             %{
               "name" => "search_docs",
               "description" => "Search docs",
               "inputSchema" => %{"type" => "object"}
             }
           ]
         }}
      )

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")

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

    test "back_to_presets returns to preset grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s([phx-click="select_preset"][phx-value-name="filesystem"]))
      |> render_click()

      html =
        view
        |> element(~s(el-dm-button[phx-click="back_to_presets"]))
        |> render_click()

      assert html =~ "Select an MCP Server"
    end

    test "preset with required env shows env textarea with placeholders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s([phx-click="select_preset"][phx-value-name="github"]))
        |> render_click()

      assert html =~ "GITHUB_PERSONAL_ACCESS_TOKEN"
      assert html =~ "Fill in the required environment variable values"
    end
  end
end
