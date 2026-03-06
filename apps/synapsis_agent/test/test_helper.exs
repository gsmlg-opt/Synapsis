Ecto.Adapters.SQL.Sandbox.mode(Synapsis.Repo, :manual)

# Start RunRegistry for tests if not already started (may be started by synapsis_core)
case Registry.start_link(keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
