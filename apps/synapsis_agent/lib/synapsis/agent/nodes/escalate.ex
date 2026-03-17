defmodule Synapsis.Agent.Nodes.Escalate do
  @moduledoc "Invokes AuditorTask with LLM call for escalation analysis. Pauses while auditor runs."
  @behaviour Synapsis.Agent.Runtime.Node

  import Synapsis.Agent.Nodes.Helpers, only: [worker_pid: 1]

  require Logger

  @impl true
  def run(state, _ctx) do
    if state[:awaiting_auditor] do
      # Auditor completed (resumed after async task) — proceed back to build_prompt
      new_state = Map.delete(state, :awaiting_auditor)
      {:next, :default, new_state}
    else
      session_id = state.session_id

      Logger.info("escalation_started", session_id: session_id)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session_id}",
        {"auditing", %{reason: to_string(state.decision)}}
      )

      if pid = worker_pid(session_id) do
        send(
          pid,
          {:node_request, :start_auditor,
           %{
             session_id: session_id,
             monitor: state.monitor,
             agent_config: state.agent_config,
             decision: state.decision
           }}
        )
      end

      {:wait, Map.put(state, :awaiting_auditor, true)}
    end
  end
end
