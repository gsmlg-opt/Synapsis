defmodule Synapsis.Agent.Nodes.ReceiveMessage do
  @moduledoc "Waits for user input. Pauses graph until Runner.resume/2 provides user message."
  @behaviour Synapsis.Agent.Runtime.Node

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()} | {:wait, map()}
  def run(state, ctx) do
    if state[:awaiting_input] do
      # Resumed with user input via ctx
      input = ctx[:user_input]
      image_parts = ctx[:image_parts] || []

      new_state =
        state
        |> Map.put(:user_input, input)
        |> Map.put(:image_parts, image_parts)
        |> Map.delete(:awaiting_input)

      {:next, :default, new_state}
    else
      # No input yet — pause and wait for external resume
      {:wait, Map.put(state, :awaiting_input, true)}
    end
  end
end
