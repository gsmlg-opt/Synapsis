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

  defp start_available(config, availability \\ :runtime) do
    start_function =
      if availability == :reconciliation, do: :start_reconciliation_link, else: :start_link

    spec = %{
      id: {:mcp, config.name},
      start: {Server, start_function, [config]},
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
    restart(config, :runtime)
  end

  @doc false
  def restart_for_reconciliation(%MCPConfig{} = config) do
    restart(config, :reconciliation)
  end

  defp restart(%MCPConfig{} = config, availability) do
    case current_config(config) do
      {:ok, current} ->
        case cleanup_runtime(config.id, [current.name, config.name]) do
          :ok ->
            case start_after_cleanup(current, availability) do
              {:ok, pid} -> await_restart(pid, current)
              {:error, _} = error -> error
            end

          {:error, reason} ->
            {:error, {:restart_cleanup_failed, reason}}
        end

      {:error, current_reason} ->
        case cleanup_runtime(config.id, [config.name]) do
          :ok ->
            {:error, current_reason}

          {:error, cleanup_reason} ->
            {:error, {:restart_cleanup_failed, current_reason, cleanup_reason}}
        end
    end
  end

  def list do
    Synapsis.MCP.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      Synapsis.MCP.Registry
      |> Registry.keys(pid)
      |> Enum.filter(&is_binary/1)
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
      Registry.lookup(Synapsis.MCP.Registry, name) == [] ->
        :ok

      tries <= 0 ->
        {:error, {:runtime_stop_timeout, name}}

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

  defp cleanup_runtime(config_id, names) do
    selectors =
      case config_id do
        nil -> names
        id -> [{:config_id, id} | names]
      end

    errors =
      selectors
      |> Enum.uniq()
      |> Enum.reduce([], fn selector, errors ->
        case stop_selector(selector) do
          :ok -> errors
          {:error, reason} -> [reason | errors]
        end
      end)
      |> Enum.reverse()

    case errors do
      [] -> :ok
      [reason] -> {:error, reason}
      reasons -> {:error, {:multiple_runtime_cleanup_failures, reasons}}
    end
  end

  defp stop_selector({:config_id, id}), do: stop_by_config_id(id)
  defp stop_selector(name), do: stop_and_wait(name)

  defp stop_by_config_id(nil), do: :ok

  defp stop_by_config_id(id) do
    key = {:config_id, id}

    Synapsis.MCP.Registry
    |> Registry.lookup(key)
    |> Enum.each(fn {pid, _value} ->
      _ = DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, pid)
    end)

    wait_gone(key)
  end

  defp await_restart(pid, config) do
    case Server.await_ready(pid) do
      :ok ->
        :ok

      {:error, reason} = error ->
        _ = DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, pid)

        case cleanup_runtime(config.id, [config.name]) do
          :ok ->
            error

          {:error, cleanup_reason} ->
            {:error, {:restart_cleanup_failed, reason, cleanup_reason}}
        end
    end
  end

  defp start_resolved(config) do
    if MCPConfigs.runtime_available?(config) do
      start_available(config)
    else
      {:error, :mcp_unavailable}
    end
  end

  defp start_after_cleanup(config, :runtime), do: start(config)

  defp start_after_cleanup(config, :reconciliation) do
    with {:ok, current} <- current_config(config) do
      if MCPConfigs.reconciliation_available?(current) do
        start_available(current, :reconciliation)
      else
        {:error, :mcp_unavailable}
      end
    end
  end
end
