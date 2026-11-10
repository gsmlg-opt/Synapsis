# All umbrella apps share one test VM and config store. Earlier apps' tests may
# clear the agent store, so restore the default agents seeded at boot.
Synapsis.AgentConfigs.seed_defaults()

ExUnit.start(exclude: [:functional])
