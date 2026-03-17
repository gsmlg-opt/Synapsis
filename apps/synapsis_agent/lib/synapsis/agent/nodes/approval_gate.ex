defmodule Synapsis.Agent.Nodes.ApprovalGate do
  @moduledoc """
  Pauses graph waiting for user approval/denial of tool uses.
  Resumed via Runner.resume/2 with approval_decisions in ctx.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  @impl true
  def run(state, ctx) do
    if state[:awaiting_approval] do
      # Resumed with approval decisions
      decisions = ctx[:approval_decisions] || %{}
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

      new_state =
        state
        |> Map.put(:classified_tools, updated)
        |> Map.delete(:awaiting_approval)

      if has_any_approved do
        {:next, :approved, new_state}
      else
        {:next, :denied, new_state}
      end
    else
      # Broadcast permission requests to UI and notify Worker
      if pid = worker_pid(state.session_id) do
        tool_ids =
          for {_, tu} <- state[:classified_tools] || [], do: tu.tool_use_id

        send(pid, {:node_request, :request_approvals, tool_ids})
      end

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

      {:wait, Map.put(state, :awaiting_approval, true)}
    end
  end

  defp worker_pid(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
