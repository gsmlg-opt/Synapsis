defmodule Synapsis.Agent.Nodes.Act do
  @moduledoc """
  Routes the conversational loop based on LLM response intent.

  Flushes accumulated text/reasoning/tools to DB, then selects the next node:

  - `:respond`  — no tool calls; reply directly to the user (Phase 1 only path)
  - `:spawn`    — tool calls requesting a Code Agent (Phase 3+)
  - `:delegate` — routing to a Project Agent (Phase 3+)

  Phase 1: always routes to `:respond`. The routing logic is a stub that will
  be expanded in Phase 3 when `agent_send` and `spawn_coding_agent` tools land.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ResponseFlusher

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id

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

    # Phase 1: all responses are direct. Phase 3+ will inspect tool_uses to
    # detect agent-spawn intent and route to :spawn or :delegate.
    {:next, :respond, new_state}
  end
end
