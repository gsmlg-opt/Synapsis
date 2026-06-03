defmodule Synapsis.Memory.Supervisor do
  @moduledoc "Supervises memory system processes: Writer and Cache."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    adapter = Application.get_env(:synapsis_core, :memory_adapter, Synapsis.Memory.FileAdapter)

    adapter_child =
      if function_exported?(adapter, :start_link, 1) do
        [adapter]
      else
        []
      end

    children =
      adapter_child ++ [Synapsis.Memory.EventLog, Synapsis.Memory.Cache, Synapsis.Memory.Writer]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
