defmodule SynapsisPlugin.Supervisor do
  @moduledoc "Supervisor for the plugin system - Registry + DynamicSupervisor for plugin servers."
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: SynapsisPlugin.Registry},
      {DynamicSupervisor, name: SynapsisPlugin.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def start_plugin(plugin_module, name, config) do
    spec =
      Supervisor.child_spec(
        {SynapsisPlugin.Server,
         plugin_module: plugin_module, name: name, config: config},
        restart: :transient,
        id: {:plugin, name}
      )

    DynamicSupervisor.start_child(SynapsisPlugin.DynamicSupervisor, spec)
  end

  def stop_plugin(name) do
    case Registry.lookup(SynapsisPlugin.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(SynapsisPlugin.DynamicSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  def list_plugins do
    SynapsisPlugin.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(SynapsisPlugin.Registry, pid) do
        [name | _] -> %{name: name, pid: pid}
        [] -> %{name: :unknown, pid: pid}
      end
    end)
  end
end
