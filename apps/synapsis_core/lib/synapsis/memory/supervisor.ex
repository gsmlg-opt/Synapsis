defmodule Synapsis.Memory.Supervisor do
  @moduledoc "Supervises memory system processes: Writer and Cache."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Synapsis.Memory.Cache,
      Synapsis.Memory.Writer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
