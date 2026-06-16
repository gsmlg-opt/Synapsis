defmodule Synapsis.MCP do
  @moduledoc "Public API for managing MCP servers (anubis_mcp clients)."
  require Logger

  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  def start(%Synapsis.MCPConfig{} = config) do
    spec = %{
      id: {:mcp, config.name},
      start: {Server, :start_link, [config]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Synapsis.MCP.DynamicSupervisor, spec)
  end

  def stop(name) do
    case Registry.lookup(Synapsis.MCP.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  def restart(%Synapsis.MCPConfig{} = config) do
    _ = stop(config.name)
    wait_gone(config.name)

    case start(config) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  def list do
    Synapsis.MCP.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Synapsis.MCP.Registry, pid) do
        [name | _] -> [name]
        [] -> []
      end
    end)
  end

  def start_enabled do
    for cfg <- MCPConfigs.enabled() do
      case start(cfg) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("mcp_autostart_failed", server: cfg.name, reason: inspect(reason))
      end
    end

    :ok
  end

  defp wait_gone(name, tries \\ 50) do
    cond do
      tries <= 0 ->
        :ok

      Registry.lookup(Synapsis.MCP.Registry, name) == [] ->
        :ok

      true ->
        Process.sleep(20)
        wait_gone(name, tries - 1)
    end
  end
end
