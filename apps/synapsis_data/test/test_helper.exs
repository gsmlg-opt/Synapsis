# Start the Repo for standalone test runs (synapsis_data is a library app,
# so the Repo isn't started by an application supervisor).
{:ok, _} = Synapsis.Repo.start_link(Synapsis.Repo.config())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Synapsis.Repo, :manual)
