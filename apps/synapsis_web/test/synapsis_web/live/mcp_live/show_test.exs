defmodule SynapsisWeb.MCPLive.ShowTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.MCPConfigs

  defmodule FakeMCPServer do
    use GenServer

    def start_link(name) do
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

  setup do
    Synapsis.DataCase.clear_config_store(:mcp)

    {:ok, config} =
      MCPConfigs.create(%{
        name: "test-server",
        transport: "stdio",
        command: "npx test-server"
      })

    %{config: config}
  end

  test "renders config details", %{conn: conn, config: config} do
    {:ok, view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "test-server"
    assert html =~ "npx test-server"
    assert has_element?(view, "[data-form-id='mcp-config-form']")
    assert_unique_form_ids(html)
  end

  test "redirects for missing config", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/settings/mcp"}}} =
      live(conn, ~p"/settings/mcp/#{Ecto.UUID.generate()}")
  end

  test "updates config", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{"command" => "npx updated-server"})

    html = render(view)
    assert html =~ "npx updated-server"
  end

  test "shows breadcrumb with Settings / MCP Servers / name", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Settings"
    assert html =~ "MCP Servers"
    assert html =~ config.name
  end

  test "shows transport selector with current value", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Transport"
    assert html =~ "stdio"
    assert html =~ "Streamable HTTP"
  end

  test "shows enabled checkbox", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Enabled"
    assert html =~ ~s(name="enabled")
  end

  test "heading displays config name", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert has_element?(view, "h1", config.name)
  end

  test "update_config shows success flash", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{"command" => "updated-cmd"})

    assert render(view) =~ "MCP server updated"
  end

  test "shows save button", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert has_element?(view, "el-dm-button[type='submit']", "Save Changes")
  end

  test "shows URL field", %{conn: conn, config: config} do
    {:ok, http_config} =
      MCPConfigs.update(config, %{
        transport: "streamable_http",
        command: "",
        args: [],
        env: %{},
        url: "http://example.com/mcp"
      })

    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{http_config.id}")

    assert html =~ "URL"
    assert html =~ "&quot;name&quot;:&quot;url&quot;"
    assert html =~ "Headers (Name: Value, one per line)"
    refute html =~ "Command"
    refute html =~ "Arguments (one per line)"
    refute html =~ "Environment Variables"
  end

  test "shows args textarea", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Arguments (one per line)"
    assert html =~ ~s(name="args")
  end

  test "shows env textarea", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Environment Variables"
    assert html =~ ~s(name="env")
  end

  test "switching transport to HTTP shows URL and headers fields", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    html =
      view
      |> react_form_change("mcp-config-form", %{"transport" => "streamable_http"})

    assert html =~ "URL"
    assert html =~ "Headers (Name: Value, one per line)"
    refute html =~ "Command"
    refute html =~ "Arguments (one per line)"
    refute html =~ "Environment Variables"
  end

  test "preserves transport drafts when switching back to stdio", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    react_form_change(view, "mcp-config-form", %{
      "command" => "draft-command",
      "args" => "--draft",
      "transport" => "streamable_http"
    })

    react_form_change(view, "mcp-config-form", %{
      "url" => "http://localhost:7331/mcp",
      "transport" => "stdio"
    })

    react_form_submit(view, "mcp-config-form", %{})
    updated = MCPConfigs.get(config.id)
    assert updated.command == "draft-command"
    assert updated.args == ["--draft"]
    assert updated.transport == "stdio"
    assert updated.url in [nil, ""]
  end

  test "config with env vars displays them formatted", %{conn: conn} do
    {:ok, config_with_env} =
      MCPConfigs.create(%{
        name: "env-show-test",
        transport: "stdio",
        command: "test",
        env: %{"TOKEN" => "abc123", "SECRET" => "xyz789"}
      })

    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config_with_env.id}")
    assert html =~ "TOKEN=abc123"
    assert html =~ "SECRET=xyz789"
  end

  test "config with args displays them one per line", %{conn: conn} do
    {:ok, config_with_args} =
      MCPConfigs.create(%{
        name: "args-show-test",
        transport: "stdio",
        command: "test",
        args: ["--verbose", "--port=8080"]
      })

    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config_with_args.id}")
    assert html =~ "--verbose"
    assert html =~ "--port=8080"
  end

  test "submitting form with empty args and env clears them", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{"command" => "some-cmd", "args" => "", "env" => ""})

    html = render(view)
    assert html =~ "MCP server updated"
  end

  test "submitting form with args as newline-delimited list", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{
      "command" => "cmd",
      "args" => "--verbose\n--debug\n"
    })

    html = render(view)
    assert html =~ "MCP server updated"
    assert html =~ "--verbose"
    assert html =~ "--debug"
  end

  test "submitting form with env vars as KEY=VALUE lines", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{
      "command" => "cmd",
      "env" => "MYVAR=hello\nOTHER=world\nINVALID_LINE_NO_EQUALS\n"
    })

    html = render(view)
    assert html =~ "MCP server updated"
    assert html =~ "MYVAR=hello"
    assert html =~ "OTHER=world"
  end

  test "submitting form with http transport updates transport and url", %{
    conn: conn,
    config: config
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_change("mcp-config-form", %{"transport" => "streamable_http"})

    view
    |> react_form_submit("mcp-config-form", %{
      "transport" => "streamable_http",
      "url" => "http://example.com/mcp",
      "headers" => "Authorization: Bearer test-token\nX-Client: synapsis\ninvalid"
    })

    html = render(view)
    assert html =~ "MCP server updated"

    updated = MCPConfigs.get(config.id)
    assert updated.transport == "streamable_http"
    assert updated.url == "http://example.com/mcp"
    assert updated.command in [nil, ""]
    assert updated.args == []
    assert updated.env == %{}

    assert updated.headers == %{
             "Authorization" => "Bearer test-token",
             "X-Client" => "synapsis"
           }
  end

  test "invalid header input shows guidance and preserves saved config", %{
    conn: conn,
    config: config
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_change("mcp-config-form", %{"transport" => "streamable_http"})

    html =
      view
      |> react_form_submit("mcp-config-form", %{
        "transport" => "streamable_http",
        "url" => "http://localhost/mcp",
        "headers" => ~s({"Authorization":"Bearer test-token"})
      })

    assert html =~ "Invalid headers. Use Name: Value, one per line, without JSON braces."
    assert MCPConfigs.get(config.id).transport == "stdio"
    assert MCPConfigs.get(config.id).headers == %{}
  end

  test "enabled checkbox — submitting with false value", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{"command" => "test", "enabled" => "false"})

    assert render(view) =~ "MCP server updated"
  end

  test "disabling a running server stops it and unregisters its tools", %{
    conn: conn,
    config: config
  } do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Synapsis.MCP.DynamicSupervisor,
        %{
          id: {:show_fake, config.name},
          start: {FakeMCPServer, :start_link, [config.name]},
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

    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> react_form_submit("mcp-config-form", %{"command" => config.command, "enabled" => "false"})

    refute MCPConfigs.get(config.id).enabled
    assert wait_until(fn -> not Process.alive?(pid) end)

    assert wait_until(fn ->
             Synapsis.Tool.Registry.lookup(tool_name) == {:error, :not_found}
           end)

    refute config.name in Synapsis.MCP.list()
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
