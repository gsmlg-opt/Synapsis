defmodule Synapsis.Agent.Nodes.ToolDispatch do
  @moduledoc "Checks permissions for pending tool uses. Routes to approval or execution."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ToolDispatcher
  alias Synapsis.Session
  alias Synapsis.Session.Store

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    case Store.get_meta(state.session_id) do
      {:error, :not_found} ->
        {:next, :all_approved,
         Map.put(state, :classified_tools, Enum.map(state.tool_uses, &{:approved, &1}))}

      {:ok, meta} ->
        run_with_session(state, Session.from_meta(meta))
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
