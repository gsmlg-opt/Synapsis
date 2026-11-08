defmodule Synapsis.Agent.Graphs.CodingLoop do
  @moduledoc "Pure initial-state compatibility helper for session metadata."

  @doc "Returns a fresh workflow state for a new coding loop run."
  @spec initial_state(map()) :: map()
  def initial_state(opts) do
    %{
      session_id: opts[:session_id],
      messages: [],
      pending_text: "",
      pending_tool_use: nil,
      pending_tool_input: "",
      pending_reasoning: "",
      pending_reasoning_signature: "",
      pending_provider_states: [],
      tool_uses: [],
      iteration_activity: %{text_emitted: false, tool_calls_emitted: 0, tool_results_received: 0},
      monitor: Synapsis.Session.Monitor.new(),
      iteration_count: 0,
      provider_config: opts[:provider_config] || %{},
      agent_config: opts[:agent_config] || %{},
      decision: nil,
      tool_call_hashes: MapSet.new(),
      user_input: nil,
      approval_decisions: %{},
      empty_completion_retries: 0
    }
  end
end
