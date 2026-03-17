defmodule Synapsis.Agent.Nodes.ToolExecute do
  @moduledoc "Executes approved tools via Worker dispatch. Pauses while tools run."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.ResponseFlusher

  @impl true
  def run(state, ctx) do
    if state[:awaiting_tools] do
      # Tools completed — proceed to orchestrator
      new_state =
        state
        |> Map.delete(:awaiting_tools)
        |> Map.delete(:classified_tools)
        |> Map.put(:tool_uses, [])

      {:next, :default, new_state}
    else
      classified = state[:classified_tools] || []
      session_id = state.session_id

      # Handle denied tools immediately
      denied = Enum.filter(classified, fn {status, _} -> status == :denied end)

      for {_, tool_use} <- denied do
        ResponseFlusher.flush_tool_result(
          session_id,
          tool_use.tool_use_id,
          "Tool denied by permission policy.",
          true
        )
      end

      approved =
        Enum.filter(classified, fn {status, _} -> status in [:approved, :auto_approved] end)

      if Enum.empty?(approved) do
        # All denied — proceed directly
        new_state =
          state
          |> Map.delete(:classified_tools)
          |> Map.put(:tool_uses, [])

        {:next, :default, new_state}
      else
        # Dispatch approved tools via Worker
        if pid = worker_pid(state.session_id) do
          dispatch_opts = %{
            project_path: ctx[:project_path],
            effective_path: state.worktree_path || ctx[:project_path],
            session_id: session_id,
            agent_id: state.agent_config[:name] || "default",
            project_id: ctx[:project_id],
            tool_call_hashes: state.tool_call_hashes,
            worktree_path: state.worktree_path
          }

          send(pid, {:node_request, :dispatch_tools, approved, dispatch_opts})
        end

        {:wait, Map.put(state, :awaiting_tools, true)}
      end
    end
  end

  defp worker_pid(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
