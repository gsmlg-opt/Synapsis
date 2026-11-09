defmodule Synapsis.Session.Worker.ContractVersionConfigTest do
  use ExUnit.Case, async: false

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
end
