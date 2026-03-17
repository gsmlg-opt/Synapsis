defmodule Synapsis.Agent.Nodes.ToolExecute do
  @moduledoc "Executes approved tools via ToolDispatcher. Pauses while tools run, resumes when all complete."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.{ToolDispatcher, ResponseFlusher}

  @impl true
  def run(state, ctx) do
    case state[:tools_completed] do
      true ->
        # Tools already completed (resumed after execution) — proceed
        new_state = Map.delete(state, :tools_completed)
        new_state = Map.delete(new_state, :classified_tools)
        {:next, :default, new_state}

      _ ->
        # Dispatch tools and wait
        classified = state[:classified_tools] || []
        session_id = state.session_id

        # Only execute approved tools
        approved =
          Enum.filter(classified, fn {status, _} -> status == :approved end)

        dispatch_opts = %{
          project_path: ctx[:project_path],
          effective_path: state.worktree_path || ctx[:project_path],
          session_id: session_id,
          agent_id: state.agent_config[:name] || "default",
          project_id: ctx[:project_id],
          tool_call_hashes: state.tool_call_hashes,
          worktree_path: state.worktree_path
        }

        # For denied tools, create denial results
        denied = Enum.filter(classified, fn {status, _} -> status == :denied end)

        for {_, tool_use} <- denied do
          ResponseFlusher.flush_tool_result(
            session_id,
            tool_use.tool_use_id,
            "Tool denied by permission policy.",
            true
          )
        end

        if Enum.empty?(approved) do
          # All denied — proceed directly
          new_state = %{state | tool_uses: []}
          new_state = Map.delete(new_state, :classified_tools)
          {:next, :default, new_state}
        else
          new_hashes =
            ToolDispatcher.dispatch_all(approved, self(), session_id, dispatch_opts)

          new_state = %{state | tool_call_hashes: new_hashes}
          {:wait, new_state}
        end
    end
  end
end
