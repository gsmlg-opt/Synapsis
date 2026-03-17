defmodule Synapsis.Agent.Nodes.ApprovalGate do
  @moduledoc """
  Pauses graph waiting for user approval/denial of tool uses.
  Resumed via Runner.resume/2 with approval_decisions in ctx.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  @impl true
  def run(state, _ctx) do
    case state[:approval_decisions] do
      decisions when is_map(decisions) and map_size(decisions) > 0 ->
        # Decisions provided via resume — process them
        classified = state[:classified_tools] || []

        updated =
          Enum.map(classified, fn {status, tool_use} ->
            case Map.get(decisions, tool_use.tool_use_id) do
              :approved -> {:approved, tool_use}
              :denied -> {:denied, tool_use}
              _ -> {status, tool_use}
            end
          end)

        has_any_approved = Enum.any?(updated, fn {s, _} -> s == :approved end)

        new_state = Map.put(state, :classified_tools, updated)
        new_state = Map.put(new_state, :approval_decisions, %{})

        if has_any_approved do
          {:next, :approved, new_state}
        else
          {:next, :denied, new_state}
        end

      _ ->
        # No decisions yet — pause and broadcast permission requests
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{state.session_id}",
          {"permission_requests",
           %{
             tools:
               Enum.map(state[:classified_tools] || [], fn {_, tu} ->
                 %{tool: tu.tool, tool_use_id: tu.tool_use_id, input: tu.input}
               end)
           }}
        )

        {:wait, state}
    end
  end
end
