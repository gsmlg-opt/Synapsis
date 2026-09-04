defmodule Synapsis.MCP do
  @moduledoc "Public API for managing MCP servers."
  require Logger

  alias Synapsis.MCP.Server
  alias Synapsis.{MCPConfig, MCPConfigs}

  def start(%MCPConfig{} = config) do
    with {:ok, current} <- current_config(config) do
      start_resolved(current)
    end
  end

  defp start_available(config) do
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

  def restart(%MCPConfig{} = config) do
    case current_config(config) do
      {:ok, current} ->
        Enum.each(Enum.uniq([config.name, current.name]), &stop_and_wait/1)

        case start(current) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        stop_and_wait(config.name)
        error
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

  defp current_config(%MCPConfig{id: nil} = config), do: {:ok, config}

  defp current_config(%MCPConfig{id: id}) do
    case MCPConfigs.get(id) do
      nil -> {:error, :mcp_unavailable}
      config -> {:ok, config}
    end
  end

  defp stop_and_wait(name) do
    _ = stop(name)
    wait_gone(name)
  end

  defp start_resolved(config) do
    if MCPConfigs.runtime_available?(config) do
      start_available(config)
    else
      {:error, :mcp_unavailable}
    end
  end
end
