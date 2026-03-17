ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Synapsis.Repo, :manual)

# Start registries that were moved to SynapsisAgent.Application.
# These are needed for Worker/Session tests in synapsis_core.
Registry.start_link(keys: :unique, name: Synapsis.Session.Registry)
Registry.start_link(keys: :unique, name: Synapsis.Session.SupervisorRegistry)
Synapsis.Session.DynamicSupervisor.start_link([])
Registry.start_link(keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry)
