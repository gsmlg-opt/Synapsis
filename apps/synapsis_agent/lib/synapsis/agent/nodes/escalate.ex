defmodule Synapsis.Agent.Nodes.Escalate do
  @moduledoc "Invokes AuditorTask with LLM call for escalation analysis. Pauses while auditor runs."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Session.AuditorTask
  require Logger

  @impl true
  def run(state, _ctx) do
    case state[:auditor_completed] do
      true ->
        # Auditor completed (resumed after async task) — proceed back to build_prompt
        new_state = Map.delete(state, :auditor_completed)
        {:next, :default, new_state}

      _ ->
        session_id = state.session_id
        monitor = state.monitor
        agent_config = state.agent_config

        Logger.info("escalation_started", session_id: session_id)

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {"auditing", %{reason: to_string(state.decision)}}
        )

        # Prepare and dispatch auditor task asynchronously
        auditor_request = AuditorTask.prepare_escalation(session_id, monitor, agent_config)

        new_state = Map.put(state, :auditor_request, auditor_request)
        {:wait, new_state}
    end
  end
end
