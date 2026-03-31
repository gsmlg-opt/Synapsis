defmodule Synapsis.Agent.Nodes.Orchestrate do
  @moduledoc "Consults Monitor and Orchestrator to decide: continue, pause, escalate, or terminate."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Session.{Monitor, Orchestrator}

  @max_tool_iterations 25

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    iteration_count = state.iteration_count + 1
    has_output = state.pending_text != "" or length(state.tool_uses) > 0
    {_signals, monitor} = Monitor.record_iteration(state.monitor, has_output)

    max_iterations =
      Application.get_env(:synapsis_core, :max_tool_iterations, @max_tool_iterations)

    decision = Orchestrator.decide(monitor, max_iterations: max_iterations)
    applied = Orchestrator.apply_decision(decision, state.session_id)

    new_state = %{
      state
      | iteration_count: iteration_count,
        monitor: monitor,
        tool_uses: [],
        decision: applied.decision
    }

    case applied.decision do
      :continue -> {:next, :continue, new_state}
      :pause -> {:next, :pause, new_state}
      :escalate -> {:next, :escalate, new_state}
      :terminate -> {:next, :terminate, new_state}
    end
  end
end
