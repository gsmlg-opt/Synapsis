defmodule Synapsis.Agent.Nodes.ProcessResponse do
  @moduledoc "Flushes accumulated text/tools to DB via ResponseFlusher. Routes based on tool presence."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ResponseFlusher

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id

    # Flush accumulated content to DB
    acc = %{
      pending_text: Map.get(state, :pending_text, ""),
      pending_tool_use: Map.get(state, :pending_tool_use),
      pending_tool_input: Map.get(state, :pending_tool_input, ""),
      pending_reasoning: Map.get(state, :pending_reasoning, ""),
      pending_reasoning_signature: Map.get(state, :pending_reasoning_signature, ""),
      tool_uses: Map.get(state, :tool_uses, [])
    }

    flushed = ResponseFlusher.flush(session_id, acc)

    new_state =
      Map.merge(state, %{
        pending_text: flushed.pending_text,
        pending_tool_use: flushed.pending_tool_use,
        pending_tool_input: flushed.pending_tool_input,
        pending_reasoning: flushed.pending_reasoning,
        pending_reasoning_signature: flushed.pending_reasoning_signature,
        iteration_activity: %{
          text_emitted: acc.pending_text != "",
          tool_calls_emitted: length(acc.tool_uses),
          tool_results_received: 0
        }
      })

    if Enum.empty?(acc.tool_uses) do
      {:next, :no_tools, new_state}
    else
      {:next, :has_tools, new_state}
    end
  end
end
