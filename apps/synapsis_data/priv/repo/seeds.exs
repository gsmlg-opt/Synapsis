# Seeds — inserts default provider configurations.
# Safe to run multiple times (on_conflict: :nothing).
#
#   mix run apps/synapsis_data/priv/repo/seeds.exs

Synapsis.Providers.seed_defaults()
IO.puts("Default providers seeded.")
