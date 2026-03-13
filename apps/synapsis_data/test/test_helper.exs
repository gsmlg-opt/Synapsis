# Start the Repo for standalone test runs (synapsis_data is a library app,
# so the Repo isn't started by an application supervisor).
# When running as part of the umbrella, the Repo may already be started.
case Synapsis.Repo.start_link(Synapsis.Repo.config()) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Synapsis.Repo, :manual)
