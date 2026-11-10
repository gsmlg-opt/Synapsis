defmodule SynapsisWeb.NativeMCPCatalogFunctionalTest do
  use SynapsisWeb.ConnCase
  @moduletag :functional

  alias Synapsis.{AgentConfigs, MCPConfigs, Toolsets}

  def refresh, do: %{}
  def refresh_failure(id), do: %{id => {:error, :discovery_failed}}

  defmodule Source do
    use GenServer

    def start_link(config) do
      GenServer.start_link(__MODULE__, config,
        name: {:via, Registry, {Synapsis.MCP.Registry, config.name}}
      )
    end

    def init(config) do
      Registry.register(Synapsis.MCP.Registry, {:config_id, config.id}, nil)
      {:ok, %{config: config, tools: [tool(config, "echo", "Original")]}}
    end

    def handle_call(:catalog, _from, %{tools: nil} = state),
      do: {:reply, {:error, :mcp_unavailable}, state}

    def handle_call(:catalog, _from, state), do: {:reply, {:ok, state.tools}, state}

    def handle_call(:unavailable, _from, state), do: {:reply, :ok, %{state | tools: nil}}

    def handle_call(:runtime_snapshot, _from, state) do
      tools = Enum.map(state.tools, &%{raw_name: &1.mcp_tool_name, description: &1.description})
      {:reply, {:ok, %{source_id: state.config.id, tools: tools}}, state}
    end

    def handle_call({:tools, names}, _from, state) do
      tools = Enum.map(names, fn {name, description} -> tool(state.config, name, description) end)
      {:reply, :ok, %{state | tools: tools}}
    end

    defp tool(config, name, description) do
      %{
        name: "mcp:#{config.name}:#{name}",
        mcp_config_id: config.id,
        mcp_tool_name: name,
        description: description,
        parameters: %{"type" => "object"}
      }
    end
  end

  setup do
    original = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh, []})

    {:ok, source} =
      MCPConfigs.create(%{
        name: "display-source-#{System.unique_integer([:positive])}",
        command: "false"
      })

    {:ok, pid} = DynamicSupervisor.start_child(Synapsis.MCP.DynamicSupervisor, {Source, source})

    on_exit(fn ->
      Synapsis.MCP.stop(source.name)
      MCPConfigs.delete(source)

      if original,
        do: Application.put_env(:synapsis_core, :mcp_refresh, original),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    %{source: source, source_pid: pid}
  end

  test "MCP settings follow source metadata names, counts, and empty discoveries", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/settings/mcp")
    render_async(view)
    selector = "#tools-modal-#{ctx.source.id}"
    trigger = "button[commandfor='tools-modal-#{ctx.source.id}']"
    assert has_element?(view, trigger, "1 tool(s)")
    assert has_element?(view, selector, "Original")

    set_tools(ctx, [{"echo", "Replacement"}, {"second", "Second tool"}])
    assert has_element?(view, trigger, "2 tool(s)")
    assert has_element?(view, selector, "Replacement")
    refute has_element?(view, selector, "Original")

    set_tools(ctx, [])
    refute has_element?(view, selector)
    assert :ok = Synapsis.MCP.stop(ctx.source.name)
    refute has_element?(view, "[phx-click='stop_plugin'][phx-value-name='#{ctx.source.name}']")
    assert has_element?(view, "[phx-click='start_plugin'][phx-value-name='#{ctx.source.name}']")
  end

  test "legacy Agent keeps saved unavailable selections while discovery refreshes", ctx do
    policy = %{
      "default" => "selected",
      "sources" => %{
        ctx.source.id => %{"mode" => "selected", "tools" => ["echo", "saved-gone"]}
      }
    }

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "catalog-agent-#{System.unique_integer([:positive])}",
        tool_contract_version: 0,
        tools: ["mcp:#{ctx.source.name}:echo"],
        config: %{"mcp_selection" => policy}
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)

    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)
    selector = "[data-mcp-source='#{ctx.source.id}']"
    assert has_element?(view, "#{selector} input[value='echo'][checked]")
    assert has_element?(view, "#{selector} input[value='saved-gone'][checked]")

    set_tools(ctx, [{"new-discovery", "New tool"}])
    assert has_element?(view, "#{selector} input[value='new-discovery']")
    assert has_element?(view, "#{selector} input[value='echo'][checked]")
    assert has_element?(view, "#{selector} input[value='saved-gone'][checked]")
    assert AgentConfigs.get(agent.id).config["mcp_selection"] == policy
    assert AgentConfigs.get(agent.id).tool_contract_version == 0
  end

  test "legacy Agent shows a recovered source after a previous refresh failure", ctx do
    :ok = GenServer.call(ctx.source_pid, :unavailable)

    Application.put_env(
      :synapsis_core,
      :mcp_refresh,
      {__MODULE__, :refresh_failure, [ctx.source.id]}
    )

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "catalog-recovery-#{System.unique_integer([:positive])}",
        tool_contract_version: 0,
        config: %{
          "mcp_selection" => %{
            "default" => "selected",
            "sources" => %{
              ctx.source.id => %{"mode" => "selected", "tools" => []}
            }
          }
        }
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)
    selector = "[data-mcp-source='#{ctx.source.id}'] input[value='recovered']"
    refute has_element?(view, selector)

    set_tools(ctx, [{"recovered", "Recovered discovery"}])
    assert has_element?(view, selector)
  end

  test "legacy Toolset displays source tools and preserves saved names across refresh", ctx do
    echo = "mcp:#{ctx.source.name}:echo"
    saved = "mcp:#{ctx.source.name}:saved-gone"

    {:ok, toolset} =
      Toolsets.create(%{
        name: "catalog-legacy-#{System.unique_integer([:positive])}",
        tool_contract_version: 0,
        tool_names: [echo, saved]
      })

    on_exit(fn -> Toolsets.delete(toolset) end)
    {:ok, view, _} = live(ctx.conn, ~p"/agent/tools/#{toolset.id}/edit")
    render_async(view)
    assert has_element?(view, "input[value='#{echo}'][checked]")
    assert has_element?(view, "input[value='#{saved}'][checked]")

    assert has_element?(
             view,
             "[data-tool-category]:not([data-tool-category='unavailable']) input[value='#{echo}']"
           )

    set_tools(ctx, [{"fresh", "Fresh discovery"}])
    assert has_element?(view, "input[value='mcp:#{ctx.source.name}:fresh']")

    assert has_element?(
             view,
             "[data-tool-category='unavailable'] input[value='#{echo}'][checked]"
           )

    assert has_element?(view, "input[value='#{saved}'][checked]")
    assert Toolsets.get(toolset.id).tool_names == [echo, saved]
    assert Toolsets.get(toolset.id).tool_contract_version == 0
  end

  test "native Agent catalog follows source events without changing its saved selection", ctx do
    native = "mcp::#{ctx.source.id}::echo"

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "catalog-native-agent-#{System.unique_integer([:positive])}",
        tool_contract_version: 1,
        tools: [native]
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{agent.id}/config")
    selector = "[data-mcp-source='#{ctx.source.id}']"
    assert has_element?(view, "#{selector} input[value='echo'][checked]")
    set_tools(ctx, [{"fresh", "Fresh"}])
    assert has_element?(view, "#{selector} input[value='fresh']")
    assert has_element?(view, "#{selector} input[value='echo'][checked]")
    assert AgentConfigs.get(agent.id).tools == [native]
  end

  test "native Toolset catalog follows source events while empty discovery preserves saved choices",
       ctx do
    native = "mcp::#{ctx.source.id}::echo"

    {:ok, toolset} =
      Toolsets.create(%{
        name: "catalog-native-toolset-#{System.unique_integer([:positive])}",
        tool_contract_version: 1,
        tool_names: [native]
      })

    on_exit(fn -> Toolsets.delete(toolset) end)
    {:ok, view, _} = live(ctx.conn, ~p"/agent/tools/#{toolset.id}/edit")
    assert has_element?(view, "input[value='#{native}'][checked]")
    set_tools(ctx, [{"fresh", "Fresh"}])
    assert has_element?(view, "input[value='mcp::#{ctx.source.id}::fresh']")
    set_tools(ctx, [])

    assert has_element?(
             view,
             "[data-tool-category='unavailable'] input[value='#{native}'][checked]"
           )

    assert Toolsets.get(toolset.id).tool_names == [native]
  end

  defp set_tools(ctx, tools) do
    :ok = GenServer.call(ctx.source_pid, {:tools, tools})

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "tool_registry",
      {:mcp_source_catalog_changed,
       %{
         source_id: ctx.source.id,
         source_name: ctx.source.name,
         status: :ready
       }}
    )
  end
end
