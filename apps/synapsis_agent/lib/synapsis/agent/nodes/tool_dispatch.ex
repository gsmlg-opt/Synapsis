defmodule Synapsis.Agent.Nodes.ToolDispatch do
  @moduledoc "Checks permissions for pending tool uses. Routes to approval or execution."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ToolDispatcher
  alias Synapsis.{Repo, Session}

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    case Repo.get(Session, state.session_id) do
      nil ->
        {:next, :all_approved,
         Map.put(state, :classified_tools, Enum.map(state.tool_uses, &{:approved, &1}))}

      session ->
        session = Repo.preload(session, :project)
        run_with_session(state, session)
    end
  end

  defp run_with_session(state, session) do
    {classified, monitor} = ToolDispatcher.classify(state.tool_uses, session, state.monitor)

    needs_approval = Enum.any?(classified, fn {status, _} -> status == :requires_approval end)

    new_state = %{state | monitor: monitor}
    new_state = Map.put(new_state, :classified_tools, classified)

    if needs_approval do
      {:next, :needs_approval, new_state}
    else
      {:next, :all_approved, new_state}
    end
  end
end
