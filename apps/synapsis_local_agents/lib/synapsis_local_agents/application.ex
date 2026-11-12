defmodule SynapsisLocalAgents.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SynapsisLocalAgents.Registry},
      {DynamicSupervisor, name: SynapsisLocalAgents.RunnerSupervisor, strategy: :one_for_one},
      Supervisor.child_spec({Task, &boot/0}, restart: :temporary)
    ]

    opts = [strategy: :one_for_one, name: SynapsisLocalAgents.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Seed the default Codex entry and start agents marked autostart.
  defp boot do
    :ok = Synapsis.LocalAgentConfigs.ensure_default_codex()

    for %{autostart: true, id: id} <- Synapsis.LocalAgentConfigs.list(),
        do: SynapsisLocalAgents.start(id)
  end
end
