defmodule Synapsis.Agent.Nodes.ToolDispatch do
  @moduledoc "Checks permissions for pending tool uses. Routes to approval or execution."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ToolDispatcher

  @impl true
  def run(state, ctx) do
    session = ctx[:session]
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
