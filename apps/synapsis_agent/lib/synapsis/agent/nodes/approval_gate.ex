defmodule Synapsis.Agent.Nodes.ApprovalGate do
  @moduledoc """
  Pauses graph waiting for user approval/denial of tool uses.
  Resumed via Runner.resume/2 with approval_decisions in ctx.

  Checks persistent tool approvals (AI-7) before prompting the user.
  Auto-approved tools are marked as approved without user interaction.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Agent.Approval
  import Synapsis.Agent.Nodes.Helpers, only: [worker_pid: 1]

  @impl true
  def run(state, ctx) do
    if state[:awaiting_approval] do
      handle_resumed(state, ctx)
    else
      handle_initial(state)
    end
  end

  # Resumed with user approval decisions
  defp handle_resumed(state, ctx) do
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
  end

  # First entry — check persistent approvals before asking user
  defp handle_initial(state) do
    classified = state[:classified_tools] || []
    project_id = state.agent_config[:project_id]

    # Check persistent approvals for each tool
    {auto_resolved, needs_user} =
      Enum.split_with(classified, fn {_status, tool_use} ->
        case Approval.check_approval(tool_use.tool, tool_use.input || %{}, project_id: project_id) do
          :allow -> true
          :record -> true
          _ -> false
        end
      end)

    # Mark auto-resolved tools as approved
    auto_approved = Enum.map(auto_resolved, fn {_status, tu} -> {:approved, tu} end)

    if needs_user == [] do
      # All tools auto-approved via persistent approvals
      new_state = Map.put(state, :classified_tools, auto_approved)
      {:next, :approved, new_state}
    else
      # Some tools need user approval — broadcast request
      all_classified = auto_approved ++ needs_user
      new_state = Map.put(state, :classified_tools, all_classified)

      if pid = worker_pid(state.session_id) do
        tool_ids = for {_, tu} <- needs_user, do: tu.tool_use_id
        send(pid, {:node_request, :request_approvals, tool_ids})
      end

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{state.session_id}",
        {"permission_requests",
         %{
           tools:
             Enum.map(needs_user, fn {_, tu} ->
               %{tool: tu.tool, tool_use_id: tu.tool_use_id, input: tu.input}
             end)
         }}
      )

      {:wait, Map.put(new_state, :awaiting_approval, true)}
    end
  end
end
