defmodule Synapsis.Agent.Nodes.Orchestrate do
  @moduledoc "Consults Monitor and Orchestrator to decide: continue, pause, escalate, or terminate."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  alias Synapsis.Session.{Monitor, Orchestrator}

  @max_tool_iterations 25

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    iteration_count = state.iteration_count + 1
    has_output = meaningful_output?(state)
    {_signals, monitor} = Monitor.record_iteration(state.monitor, has_output)

    max_iterations =
      Application.get_env(:synapsis_core, :max_tool_iterations, @max_tool_iterations)

    decision = Orchestrator.decide(monitor, max_iterations: max_iterations)
    {decision_name, reason} = decision

    Logger.info("orchestrator_decision_observed",
      session_id: state.session_id,
      decision: decision_name,
      reason: reason
    )

    new_state =
      Map.merge(state, %{
        iteration_count: iteration_count,
        monitor: monitor,
        tool_uses: [],
        decision: decision_name,
        iteration_activity: empty_activity()
      })

    {:next, :continue, new_state}
  end

  defp meaningful_output?(state) do
    activity = Map.get(state, :iteration_activity, empty_activity())

    activity_value(activity, :text_emitted) or
      activity_value(activity, :tool_calls_emitted) > 0 or
      activity_value(activity, :tool_results_received) > 0 or
      state.pending_text != "" or
      length(state.tool_uses) > 0
  end

  defp activity_value(activity, key) do
    Map.get(activity, key, Map.get(activity, Atom.to_string(key), empty_activity()[key]))
  end

  defp empty_activity, do: %{text_emitted: false, tool_calls_emitted: 0, tool_results_received: 0}
end
