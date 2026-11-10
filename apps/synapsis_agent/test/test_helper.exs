# Start registries for tests if not already started (may be started by Application).
for name <- [Synapsis.Agent.Runtime.RunRegistry, Synapsis.Agent.RunRegistry] do
  case Registry.start_link(keys: :unique, name: name) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
  end
end

# All umbrella apps share one test VM and config store. Earlier apps' tests may
# clear the agent store, so restore the default agents seeded at boot.
Synapsis.AgentConfigs.seed_defaults()

ExUnit.start(exclude: [:functional])
