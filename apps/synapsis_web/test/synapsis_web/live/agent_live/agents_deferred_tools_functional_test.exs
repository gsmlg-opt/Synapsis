defmodule SynapsisWeb.AgentLive.AgentsDeferredToolsFunctionalTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{AgentConfigs, MCPConfigs, Toolsets}
  alias Synapsis.Config.Store

  @field ~s(input[name="agent[deferred_tool_names][]"])

  defmodule SnapshotSource do
    use GenServer

    def start_link({id, names}) do
      GenServer.start_link(__MODULE__, {id, names},
        name: {:via, Registry, {Synapsis.MCP.Registry, {:config_id, id}}}
      )
    end

    def init(state), do: {:ok, state}

    def handle_call(:runtime_snapshot, _from, {id, names} = state) do
      tools = Enum.map(names, &%{raw_name: &1, description: "Local #{&1}"})
      {:reply, {:ok, %{source_id: id, tools: tools}}, state}
    end

    def handle_call({:tools, names}, _from, {id, _names}) do
      {:reply, :ok, {id, names}}
    end
  end

  setup do
    assert String.contains?(Store.config_dir(), "config_store_test")
    assert System.get_env("MIX_TEST_PARTITION") not in [nil, ""]
    Synapsis.DataCase.clear_config_store(:mcp)
    Synapsis.DataCase.clear_config_store(:toolset)
    :ok
  end

  test "empty deferred list offers only selected native and canonical MCP names", %{conn: conn} do
    source = source!(["read::nested", "other"])
    selected = "mcp::#{source.config.id}::read::nested"

    policy = policy(source.config.id, "selected", ["read::nested"])
    agent = agent!(["synapsis::file_read"], %{"mcp_selection" => policy})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_click(view, "switch_config_tab", %{"tab" => "tools"})

    assert has_element?(view, "#agent-deferred-tools", "Deferred tools")
    assert has_element?(view, "#agent-deferred-tools", "Leave empty")
    assert names(view) == ["synapsis::file_read", selected]
    assert checked_names(view) == []
    assert values(view)["agent"]["deferred_tool_names"] == []
    assert :error = Map.fetch(AgentConfigs.get(agent.id).config, "deferred_tool_names")
  end

  test "save reopen and explicit clear retain raw selection order and unrelated configuration", %{
    conn: conn
  } do
    source = source!(["read::nested"])
    canonical = "mcp::#{source.config.id}::read::nested"
    tools = [canonical, "synapsis::file_read", canonical]

    config = %{
      "mcp_selection" => policy(source.config.id, "selected", ["read::nested"]),
      "other" => %{"keep" => [1, "two"]}
    }

    agent = agent!(tools, config)
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    deferred = [canonical, "synapsis::file_read"]

    react_form_change(view, "agent-config-form", %{
      "agent" => %{"deferred_tool_names" => deferred, "label" => "Deferred draft"}
    })

    render_click(view, "switch_config_tab", %{"tab" => "tools"})
    assert values(view)["agent"]["deferred_tool_names"] == deferred
    assert Enum.sort(checked_names(view)) == Enum.sort(deferred)
    render_click(view, "switch_config_tab", %{"tab" => "overview"})
    send(view.pid, {:tool_registry_changed, %{}})
    render(view)
    assert values(view)["agent"]["label"] == "Deferred draft"
    assert values(view)["agent"]["deferred_tool_names"] == deferred
    react_form_submit(view, "agent-config-form", %{})

    saved = AgentConfigs.get(agent.id)
    assert saved.config["deferred_tool_names"] == deferred
    assert saved.config["other"] == config["other"]
    assert saved.config["mcp_selection"] == config["mcp_selection"]
    assert saved.tools == tools
    assert saved.tool_contract_version == 1
    assert saved.label == "Deferred draft"
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(agent.id).config["deferred_tool_names"] == deferred

    {:ok, reopened, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_click(reopened, "switch_config_tab", %{"tab" => "tools"})
    assert Enum.sort(checked_names(reopened)) == Enum.sort(deferred)
    react_form_submit(reopened, "agent-config-form", %{"agent" => %{"deferred_tool_names" => []}})
    assert AgentConfigs.get(agent.id).config["deferred_tool_names"] == []
    assert AgentConfigs.get(agent.id).tools == tools
    assert AgentConfigs.get(agent.id).config["other"] == config["other"]
    assert checked_names(reopened) == []
  end

  test "linked Toolsets and current MCP group drafts determine choices without selecting discoveries",
       %{conn: conn} do
    first = source!(["one", "two::suffix"])
    second = source!(["third"])

    {:ok, toolset} =
      Toolsets.create(%{
        name: unique_name(),
        tool_contract_version: 1,
        tool_names: ["synapsis::file_read", "synapsis::session_status"]
      })

    on_exit(fn -> Toolsets.delete(toolset) end)

    policy = %{
      "default" => "all",
      "sources" => %{second.config.id => %{"mode" => "none", "tools" => []}}
    }

    agent = agent!(["synapsis::tts"], %{"mcp_selection" => policy}, %{toolset_ids: [toolset.id]})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_click(view, "switch_config_tab", %{"tab" => "tools"})
    first_names = Enum.map(["one", "two::suffix"], &"mcp::#{first.config.id}::#{&1}")
    assert names(view) == ["synapsis::file_read", "synapsis::session_status"] ++ first_names

    react_form_change(view, "agent-config-form", %{
      "mcp_selection" => %{
        "sources" => %{first.config.id => %{"mode" => "selected", "tools" => ["two::suffix"]}}
      }
    })

    assert names(view) == [
             "synapsis::file_read",
             "synapsis::session_status",
             List.last(first_names)
           ]

    react_form_change(view, "agent-config-form", %{
      "agent" => %{"deferred_tool_names" => [List.last(first_names)]}
    })

    react_form_submit(view, "agent-config-form", %{})
    saved = AgentConfigs.get(agent.id)
    assert saved.config["deferred_tool_names"] == [List.last(first_names)]
    assert saved.toolset_ids == [toolset.id]
    assert saved.tools == agent.tools
    assert Toolsets.get(toolset.id).tool_names == toolset.tool_names

    react_form_change(view, "agent-config-form", %{
      "mcp_selection" => %{"sources" => %{first.config.id => %{"mode" => "inherit"}}}
    })

    assert :ok = GenServer.call(first.pid, {:tools, ["one", "two::suffix", "future"]})
    send(view.pid, {:mcp_source_catalog_changed, %{source_id: first.config.id}})
    render(view)
    assert "mcp::#{first.config.id}::future" in names(view)
    assert checked_names(view) == [List.last(first_names)]
    assert AgentConfigs.get(agent.id).config["deferred_tool_names"] == [List.last(first_names)]
  end

  test "saved unavailable deferred entries stay checked through unrelated save and explicit removal",
       %{conn: conn} do
    missing = "mcp::#{Ecto.UUID.generate()}::saved::missing"
    deferred = [missing, "synapsis::file_read"]

    config = %{
      "deferred_tool_names" => deferred,
      "other" => %{"keep" => true},
      "mcp_selection" => %{"default" => "selected", "sources" => %{}}
    }

    agent = agent!(["synapsis::file_read"], config)
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_click(view, "switch_config_tab", %{"tab" => "tools"})

    assert has_element?(
             view,
             "#agent-deferred-tools [data-unavailable-deferred-tool='#{missing}']",
             "unavailable"
           )

    assert Enum.sort(checked_names(view)) == Enum.sort(deferred)
    react_form_submit(view, "agent-config-form", %{"agent" => %{"label" => "Keep deferred"}})
    assert AgentConfigs.get(agent.id).config["deferred_tool_names"] == deferred
    assert AgentConfigs.get(agent.id).config["other"] == config["other"]

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{"deferred_tool_names" => ["synapsis::file_read"]}
    })

    assert AgentConfigs.get(agent.id).config["deferred_tool_names"] == ["synapsis::file_read"]
  end

  defp source!(names) do
    {:ok, config} = MCPConfigs.create(%{name: unique_name(), command: "false"})
    pid = start_supervised!({SnapshotSource, {config.id, names}}, id: config.id)
    on_exit(fn -> MCPConfigs.delete(config) end)
    %{config: config, pid: pid}
  end

  defp policy(id, mode, tools) do
    %{"default" => "selected", "sources" => %{id => %{"mode" => mode, "tools" => tools}}}
  end

  defp agent!(tools, config, extra \\ %{}) do
    {:ok, agent} =
      AgentConfigs.create(
        Map.merge(
          %{name: unique_name(), tool_contract_version: 1, tools: tools, config: config},
          extra
        )
      )

    on_exit(fn -> AgentConfigs.delete(agent) end)
    agent
  end

  defp names(view), do: field_values(view, @field <> "[type='checkbox']")
  defp checked_names(view), do: field_values(view, @field <> "[type='checkbox'][checked]")

  defp field_values(view, selector) do
    view
    |> element("#agent-deferred-tools")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp values(view) do
    view
    |> element(~s([data-form-id="agent-config-form"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end

  defp unique_name, do: "deferred-ui-#{System.unique_integer([:positive, :monotonic])}"
end
