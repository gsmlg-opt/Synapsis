defmodule Synapsis.Agent.Supervisor do
  @moduledoc """
  Supervision tree for the agent subsystem.
  Started by SynapsisAgent.Application.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # ADR-006 C4: Agent.AgentRegistry (ETS GenServer + full-table scan) removed;
    # parent→child links and statuses ride the session + agent-coordination data.
    children = [
      {Registry, keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
