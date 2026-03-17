defmodule Synapsis.Agent.Nodes.Helpers do
  @moduledoc "Shared utilities for graph node modules."

  @doc "Looks up the Worker pid for a session via the Session.Registry."
  @spec worker_pid(String.t()) :: pid() | nil
  def worker_pid(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
