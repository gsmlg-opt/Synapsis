defmodule Synapsis.Session.Worker.ContractVersionConfigTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.{MCPSources, Profiles}
  alias Synapsis.Session.Worker.Config

  @moduletag :contract_version

  defmodule RefreshProbe do
    def refresh(owner) do
      send(owner, :unexpected_daemon_discovery)
      %{}
    end
  end

  setup do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{
        name: "daemon-contract-#{Ecto.UUID.generate()}",
        provider: "fixture-provider",
        model: "fixture-model",
        tools: ["send_message"],
        tool_contract_version: 1
      })

    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {RefreshProbe, :refresh, [self()]})

    on_exit(fn ->
      Synapsis.AgentConfigs.delete(agent)

      if is_nil(previous),
        do: Application.delete_env(:synapsis_core, :mcp_refresh),
        else: Application.put_env(:synapsis_core, :mcp_refresh, previous)
    end)

    %{session: %Synapsis.Session{id: Ecto.UUID.generate(), agent: agent.name, config: %{}}}
  end

  test "native agent selection retains its own provenance and provider/model", ctx do
    agent = Config.resolve_agent(ctx.session)
    assert agent.tools == ["send_message"]
    assert agent.tool_contract_version === 1
    assert agent.provider == "fixture-provider"
    assert agent.model == "fixture-model"
    refute Map.has_key?(agent, :tool_selection_error)
  end

  test "legacy daemon profile and names never inherit the original native agent version", ctx do
    for config <- [
          %{"daemon_run_tool_names" => ["send_message"]},
          %{"daemon_run_tool_names" => []},
          %{
            "daemon_run_tool_names" => ["send_message"],
            "daemon_run_tool_profile" => "read_only"
          },
          %{
            "daemon_run_tool_names" => [],
            "daemon_run_tool_profile" => "read_only",
            "tool_contract_version" => 1
          },
          %{
            "daemon_run_tool_names" => [],
            "daemon_run_tool_profile" => "read_only",
            "daemon_run_tool_contract_version" => 1
          },
          %{"daemon_run_tool_names" => [], "daemon_run_tool_profile" => "unknown"}
        ] do
      session = %{ctx.session | config: config}
      agent = Config.resolve_agent(session)
      assert Map.has_key?(agent, :tool_selection_error)
      refute agent[:tool_contract_version] === 1
      assert agent.provider == "fixture-provider"
      assert agent.model == "fixture-model"
      assert {:error, _} = Profiles.selection(%{agent: agent, session: session})
      assert {:error, _} = MCPSources.refresh(agent)
      refreshed = Config.refresh_turn_tools(agent)
      assert refreshed.tool_selection_error === agent.tool_selection_error
      refute_received :unexpected_daemon_discovery
    end
  end

  test "malformed or partial daemon override keys cannot fall back to native agent selection",
       ctx do
    for config <- [
          %{"daemon_run_tool_names" => nil},
          %{"daemon_run_tool_names" => "send_message"},
          %{"daemon_run_tool_names" => [], "daemon_run_tool_profile" => nil},
          %{"daemon_run_tool_profile" => "read_only"},
          %{daemon_run_tool_names: ["send_message"]},
          %{daemon_run_tool_profile: "read_only"},
          %{"daemon_run_tool_names" => [], daemon_run_tool_names: ["send_message"]}
        ] do
      agent = Config.resolve_agent(%{ctx.session | config: config})
      assert Map.has_key?(agent, :tool_selection_error)
      refute agent[:tool_contract_version] === 1
      assert Config.refresh_turn_tools(agent).tool_selection_error === agent.tool_selection_error
      refute_received :unexpected_daemon_discovery
    end
  end

  test "an existing invalid source error survives turn refresh without discovery" do
    agent = %{
      tools: ["send_message"],
      tool_contract_version: 0,
      tool_selection_error: {:unsupported_tool_contract_version, 0},
      daemon_tool_profile: "read_only",
      mcp_selection: %{"default" => "all", "sources" => %{}}
    }

    assert Config.refresh_turn_tools(agent) === agent
    refute_received :unexpected_daemon_discovery
  end
end
