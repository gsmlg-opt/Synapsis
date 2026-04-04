defmodule Synapsis.Agent.BuildAgentSupervisor do
  @moduledoc "DynamicSupervisor for ephemeral Build Agent processes."
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_agent(config) do
    spec = {Synapsis.Agent.Agents.BuildAgent, config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
