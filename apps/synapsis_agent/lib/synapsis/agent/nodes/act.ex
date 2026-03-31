defmodule Synapsis.Agent.Nodes.Act do
  @moduledoc """
  Routes the conversational loop based on LLM response intent.

  Flushes accumulated text/reasoning/tools to DB, then selects the next node:

  - `:respond`  — no tool calls; reply directly to the user
  - `:spawn`    — tool calls requesting a Code Agent (`task` tool detected)
  - `:delegate` — routing to a Project Agent (future)
  """
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ResponseFlusher

  # Tool names that trigger Code Agent spawning
  @spawn_tools ~w[task spawn_coding_agent]

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

    route = determine_route(new_state.tool_uses)
    {:next, route, new_state}
  end

  # If any tool_use is a spawn tool, route to :spawn. Otherwise :respond.
  defp determine_route(tool_uses) when is_list(tool_uses) do
    spawn? = Enum.any?(tool_uses, fn tu -> Map.get(tu, :name) in @spawn_tools end)
    if spawn?, do: :spawn, else: :respond
  end

  defp determine_route(_), do: :respond
end
