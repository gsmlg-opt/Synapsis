defmodule Synapsis.Agent.Nodes.ReceiveMessage do
  @moduledoc "Waits for user input. Pauses graph until Runner.resume/2 provides user message."
  @behaviour Synapsis.Agent.Runtime.Node

  @impl true
  def run(state, _ctx) do
    case state[:user_input] do
      nil ->
        # No input yet -- pause and wait for external resume with user_input
        {:wait, state}

      _input ->
        # Input provided via resume -- proceed to build_prompt
        {:next, :default, state}
    end
  end
end
