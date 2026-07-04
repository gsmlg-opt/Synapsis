defmodule Synapsis.MCP.ClientDependencyTest do
  use ExUnit.Case, async: true

  test "uses Backplane.McpProtocol as the MCP client implementation" do
    applications = Application.spec(:synapsis_mcp, :applications)

    assert Code.ensure_loaded?(Backplane.McpProtocol.Client)
    assert :backplane_mcp_protocol in applications
    refute :anubis_mcp in applications
  end
end
