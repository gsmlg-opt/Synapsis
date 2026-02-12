defmodule Synapsis.Session.DynamicSupervisor do
  @moduledoc "DynamicSupervisor for starting/stopping session process trees."
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(session_id) do
    spec = {Synapsis.Session.Supervisor, session_id: session_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(session_id) do
    case Registry.lookup(Synapsis.Session.SupervisorRegistry, session_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end
end
