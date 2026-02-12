defmodule Synapsis.MCP.Supervisor do
  @moduledoc "DynamicSupervisor for MCP client processes."
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_client(server_name, config) do
    command = config["command"]
    args = config["args"] || []
    env = config["env"] || %{}

    spec = {Synapsis.MCP.Client, server_name: server_name, command: command, args: args, env: env}

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_client(server_name) do
    case Registry.lookup(Synapsis.MCP.Registry, server_name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  def start_from_config(config) do
    mcp_servers = config["mcpServers"] || %{}

    for {name, server_config} <- mcp_servers do
      start_client(name, server_config)
    end
  end
end
