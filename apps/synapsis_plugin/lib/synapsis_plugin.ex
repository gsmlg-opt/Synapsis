defmodule SynapsisPlugin do
  @moduledoc """
  Public API for the plugin system.

  Plugins are wrappers around external processes (MCP servers, LSP servers, custom)
  that register tools into the Synapsis tool registry.
  """

  @doc "Start a plugin from a config map."
  def start_plugin(plugin_module, name, config) do
    SynapsisPlugin.Supervisor.start_plugin(plugin_module, name, config)
  end

  @doc "Stop a running plugin by name."
  def stop_plugin(name) do
    SynapsisPlugin.Supervisor.stop_plugin(name)
  end

  @doc "List all running plugins."
  def list_plugins do
    SynapsisPlugin.Supervisor.list_plugins()
  end

  @doc "Get the internal state of a running plugin by name."
  def get_plugin_state(name) do
    case Registry.lookup(SynapsisPlugin.Registry, name) do
      [{pid, _}] ->
        try do
          {:ok, GenServer.call(pid, :get_state)}
        catch
          :exit, _ -> {:error, :not_available}
        end

      [] ->
        {:error, :not_running}
    end
  end
end
