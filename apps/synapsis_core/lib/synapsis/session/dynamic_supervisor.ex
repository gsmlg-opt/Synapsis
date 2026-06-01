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
    if Synapsis.Session.Quarantine.quarantined?(session_id) do
      {:error, :quarantined}
    else
      # :temporary — a session tree that exhausts its own restart budget
      # (poison protection, ADR-006 B1) stays down rather than being
      # resurrected here; re-entry is gated by the quarantine check above.
      spec =
        Supervisor.child_spec({Synapsis.Session.Supervisor, session_id: session_id},
          restart: :temporary
        )

      DynamicSupervisor.start_child(__MODULE__, spec)
    end
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
