defmodule Synapsis.Agent.Nodes.ProcessResponse do
  @moduledoc "Flushes accumulated text/tools to DB via ResponseFlusher. Routes based on tool presence."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ResponseFlusher

  @impl true
  def run(state, _ctx) do
    session_id = state.session_id

    # Flush accumulated content to DB
    acc = %{
      pending_text: state.pending_text,
      pending_tool_use: state.pending_tool_use,
      pending_tool_input: state.pending_tool_input,
      pending_reasoning: state.pending_reasoning,
      tool_uses: state.tool_uses
    }

    flushed = ResponseFlusher.flush(session_id, acc)

    new_state = %{
      state
      | pending_text: flushed.pending_text,
        pending_tool_use: flushed.pending_tool_use,
        pending_tool_input: flushed.pending_tool_input,
        pending_reasoning: flushed.pending_reasoning
    }

    if Enum.empty?(state.tool_uses) do
      {:next, :no_tools, new_state}
    else
      {:next, :has_tools, new_state}
    end
  end
end
