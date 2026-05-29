defmodule Synapsis.Agent.Nodes.ToolExecute do
  @moduledoc "Executes approved tools via Worker dispatch. Pauses while tools run."
  @behaviour Synapsis.Agent.Runtime.Node

  import Synapsis.Agent.Nodes.Helpers, only: [worker_pid: 1]

  alias Synapsis.Agent.ResponseFlusher

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()} | {:wait, map()}
  def run(state, ctx) do
    if state[:awaiting_tools] do
      # Tools completed — proceed to orchestrator
      tool_result_count =
        state
        |> Map.get(:classified_tools, [])
        |> Enum.count(fn {status, _} -> status in [:approved, :auto_approved] end)

      new_state =
        state
        |> Map.delete(:awaiting_tools)
        |> Map.delete(:classified_tools)
        |> Map.put(:tool_uses, [])
        |> put_tool_results_received(tool_result_count)

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
            effective_path: ctx[:project_path],
            session_id: session_id,
            agent_id: state.agent_config[:name] || "default",
            tool_call_hashes: state.tool_call_hashes
          }

          send(pid, {:node_request, :dispatch_tools, approved, dispatch_opts})
        end

        {:wait, Map.put(state, :awaiting_tools, true)}
      end
    end
  end

  defp put_tool_results_received(state, count) do
    activity =
      Map.get(state, :iteration_activity, %{
        text_emitted: false,
        tool_calls_emitted: 0,
        tool_results_received: 0
      })

    Map.put(state, :iteration_activity, Map.put(activity, :tool_results_received, count))
  end
end
