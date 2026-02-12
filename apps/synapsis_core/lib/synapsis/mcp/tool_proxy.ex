defmodule Synapsis.MCP.ToolProxy do
  @moduledoc "Proxy module for executing MCP tools via the MCP client."
  @behaviour Synapsis.Tool.Behaviour

  @impl true
  def name, do: "mcp_proxy"

  @impl true
  def description, do: "Proxy for MCP tools"

  @impl true
  def parameters, do: %{}

  @impl true
  def call(input, context) do
    mcp_server = context[:mcp_server]
    mcp_tool = context[:mcp_tool]

    if mcp_server && mcp_tool do
      Synapsis.MCP.Client.call_tool(mcp_server, mcp_tool, input)
    else
      {:error, "MCP server or tool not specified in context"}
    end
  end
end
