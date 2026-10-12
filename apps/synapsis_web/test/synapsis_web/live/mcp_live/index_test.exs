defmodule SynapsisWeb.MCPLive.IndexTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

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

    @impl true
    def handle_call({:register_tool, tool_name}, _from, state) do
      :ok =
        Synapsis.Tool.Registry.register_process(tool_name, self(),
          description: "Fake tool",
          parameters: %{},
          plugin: :mcp
        )

      {:reply, :ok, state}
    end
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

    test "imports JSON through React and preserves validation feedback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      view |> element("el-dm-button[phx-click='show_import']") |> render_click()

      html = react_form_submit(view, "mcp-import-form", %{"json" => "invalid-json"})
      assert html =~ "Invalid JSON format"
      assert has_element?(view, "#mcp-import-modal [role='alert']", "Invalid JSON format")
      assert has_element?(view, "#mcp-import-modal [data-form-id='mcp-import-form']")

      json =
        Jason.encode!(%{
          "mcpServers" => %{"react-import" => %{"command" => "npx", "args" => ["--help"]}}
        })

      react_form_submit(view, "mcp-import-form", %{"json" => json})

      imported = MCPConfigs.get_by_name("react-import")
      assert imported.command == "npx"
      assert imported.args == ["--help"]
      refute has_element?(view, "[data-form-id='mcp-import-form']")
    end

    test "shows new server form on /new", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "New MCP Server"
      assert html =~ "Command"
      assert html =~ "Arguments (one per line)"
      assert html =~ "Environment Variables"
      assert has_element?(view, "[data-form-id='mcp-create-form']")
      assert_unique_form_ids(html)
    end

    test "Add MCP Server patches into a modal above the server list", %{conn: conn} do
      create_mcp_config(%{name: "behind-modal", command: "test-cmd"})
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view |> element("a[href='/settings/mcp/new']") |> render_click()
      assert_patch(view, ~p"/settings/mcp/new")

      assert has_element?(
               view,
               "dialog#mcp-create-modal[phx-hook='MCPFormModal'][data-close-event='hide_create'][aria-labelledby='mcp-create-modal-title']"
             )

      assert has_element?(view, "#mcp-create-modal-title", "New MCP Server")
      assert has_element?(view, "#mcp-create-modal #mcp-create-name[autofocus]")
      assert has_element?(view, "a[href^='/settings/mcp/']", "behind-modal")
      refute has_element?(view, "#mcp-import-modal")

      view
      |> element("#mcp-create-modal el-dm-button[phx-click='hide_create']", "Cancel")
      |> render_click()

      assert_patch(view, ~p"/settings/mcp")
      refute has_element?(view, "#mcp-create-modal")
      assert has_element?(view, "a[href^='/settings/mcp/']", "behind-modal")
    end

    test "create modal closes on Escape, backdrop and header close notifications", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      for reason <- ["escape", "backdrop", "close"] do
        view |> element("a[href='/settings/mcp/new']") |> render_click()
        assert_patch(view, ~p"/settings/mcp/new")

        assert has_element?(
                 view,
                 "#mcp-create-modal button[command='close'][commandfor='mcp-create-modal']"
               )

        render_hook(view, "hide_create", %{"reason" => reason})
        assert_patch(view, ~p"/settings/mcp")
        refute has_element?(view, "#mcp-create-modal")
      end
    end

    test "import modal closes on Cancel and native dialog notifications", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      view |> element("el-dm-button[phx-click='show_import']") |> render_click()

      assert has_element?(
               view,
               "dialog#mcp-import-modal[phx-hook='MCPFormModal'][data-close-event='hide_import'][aria-labelledby='mcp-import-modal-title']"
             )

      assert has_element?(view, "#mcp-import-modal #mcp-import-json[autofocus]")

      view
      |> element("#mcp-import-modal el-dm-button[phx-click='hide_import']", "Cancel")
      |> render_click()

      refute has_element?(view, "#mcp-import-modal")

      for reason <- ["escape", "backdrop", "close"] do
        view |> element("el-dm-button[phx-click='show_import']") |> render_click()
        render_hook(view, "hide_import", %{"reason" => reason})
        refute has_element?(view, "#mcp-import-modal")
      end
    end

    test "create and import modals replace each other and cancellation clears failed drafts", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")
      render_hook(view, "show_import", %{})
      assert_patch(view, ~p"/settings/mcp")
      assert has_element?(view, "#mcp-import-modal")
      refute has_element?(view, "#mcp-create-modal")

      react_form_submit(view, "mcp-import-form", %{"json" => "invalid-draft"})
      assert has_element?(view, "#mcp-import-modal [role='alert']")

      view
      |> element("#mcp-import-modal el-dm-button[phx-click='hide_import']", "Cancel")
      |> render_click()

      view |> element("a[href='/settings/mcp/new']") |> render_click()
      assert_patch(view, ~p"/settings/mcp/new")
      assert has_element?(view, "#mcp-create-modal")
      refute has_element?(view, "#mcp-import-modal")

      render_hook(view, "hide_create", %{})
      assert_patch(view, ~p"/settings/mcp")
      view |> element("el-dm-button[phx-click='show_import']") |> render_click()
      refute has_element?(view, "#mcp-import-modal [role='alert']")
      assert has_element?(view, "#mcp-import-json", "")
    end

    test "new form switches HTTP transport fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> react_form_change("mcp-create-form", %{
          "name" => "http-test",
          "transport" => "streamable_http"
        })

      assert html =~ "URL"
      assert html =~ "Headers (Name: Value, one per line)"
      assert html =~ ~s(name="headers")
      refute html =~ "Command"
      refute html =~ "Arguments (one per line)"
      refute html =~ "Environment Variables"
      assert_unique_form_ids(html)
    end

    test "creates MCP config from stdio form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> react_form_submit("mcp-create-form", %{
        "name" => "custom-test",
        "command" => "npx -y test-server",
        "transport" => "stdio"
      })

      assert_patch(view, "/settings/mcp")
      assert render(view) =~ "MCP server added"
      refute has_element?(view, "#mcp-create-modal")
    end

    test "creates HTTP MCP config from form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> react_form_change("mcp-create-form", %{
        "name" => "http-test",
        "transport" => "streamable_http"
      })

      view
      |> react_form_submit("mcp-create-form", %{
        "name" => "http-test",
        "transport" => "streamable_http",
        "url" => "http://localhost:7331/mcp",
        "headers" => "Authorization: Bearer test-token\nX-Workspace: docs\ninvalid"
      })

      assert_patch(view, "/settings/mcp")
      assert render(view) =~ "MCP server added"
      refute has_element?(view, "#mcp-create-modal")

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

    test "rejects JSON pasted into the line-based headers field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> react_form_change("mcp-create-form", %{"transport" => "streamable_http"})

      html =
        view
        |> react_form_submit("mcp-create-form", %{
          "name" => "invalid-json-headers",
          "transport" => "streamable_http",
          "url" => "http://localhost/mcp",
          "headers" => ~s({"Authorization":"Bearer test-token"})
        })

      assert html =~ "Invalid headers. Use Name: Value, one per line, without JSON braces."
      assert has_element?(view, "#mcp-create-modal [role='alert']", "Invalid headers")
      assert MCPConfigs.get_by_name("invalid-json-headers") == nil
    end

    test "deletes MCP config", %{conn: conn} do
      config = create_mcp_config(%{name: "deletable", command: "test-cmd"})

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "deletable"

      view
      |> element(~s(button[phx-click="delete_config"][phx-value-id="#{config.id}"]))
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

    test "disabling a running MCP stops it and unregisters its tools", %{conn: conn} do
      config = create_mcp_config(%{name: "disable-running", command: "test", enabled: true})

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Synapsis.MCP.DynamicSupervisor,
          %{
            id: {:fake, config.name},
            start: {FakeMCPServer, :start_link, [[name: config.name]]},
            restart: :temporary
          }
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, pid)
        end
      end)

      tool_name = "mcp:#{config.name}:fake"
      assert :ok = GenServer.call(pid, {:register_tool, tool_name})
      assert {:ok, {:process, ^pid, _opts}} = Synapsis.Tool.Registry.lookup(tool_name)

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Running"

      view
      |> element(~s(input[phx-click="toggle_enabled"][phx-value-id="#{config.id}"]))
      |> render_click()

      refute MCPConfigs.get(config.id).enabled
      assert wait_until(fn -> not Process.alive?(pid) end)

      assert wait_until(fn ->
               Synapsis.Tool.Registry.lookup(tool_name) == {:error, :not_found}
             end)

      refute config.name in Synapsis.MCP.list()
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

      {:ok, view, html} = live(conn, ~p"/settings/mcp")

      assert html =~ "Running"
      assert html =~ "1 tool(s)"

      assert has_element?(
               view,
               ~s(button[command="show-modal"][commandfor="tools-modal-#{config.id}"]),
               "1 tool(s)"
             )

      refute html =~ ".show()"
    end

    test "running server refreshes tools after registry change", %{conn: conn} do
      config = create_mcp_config(%{name: "refresh-tools-server", command: "test"})

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Synapsis.MCP.DynamicSupervisor,
          %{
            id: {:fake, config.name},
            start: {FakeMCPServer, :start_link, [[name: config.name]]},
            restart: :temporary
          }
        )

      {:ok, view, html} = live(conn, ~p"/settings/mcp")

      assert html =~ "Running"
      refute html =~ "1 tool(s)"

      tool_name = "mcp:#{config.name}:search_docs"

      Synapsis.Tool.Registry.register_process(tool_name, self(),
        description: "Search docs",
        parameters: %{},
        plugin: :mcp
      )

      on_exit(fn -> Synapsis.Tool.Registry.unregister(tool_name) end)

      assert wait_until(fn -> render(view) =~ "1 tool(s)" end)
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

  defp wait_until(fun, tries \\ 100) do
    cond do
      tries <= 0 ->
        false

      fun.() ->
        true

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
