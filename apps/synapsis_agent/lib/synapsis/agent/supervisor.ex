defmodule Synapsis.Agent.Supervisor do
  @moduledoc """
  Supervision tree for the agent subsystem.
  Started by SynapsisCore.Application — synapsis_agent is a pure library.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Synapsis.Agent.ProjectRegistry},
      {Registry, keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Synapsis.Agent.ProjectSupervisor},
      Synapsis.Agent.GlobalAssistant
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
