defmodule Synapsis.Agent.Nodes.SpawnAgent do
  @moduledoc """
  Spawns a Code Agent session from the conversational loop.

  Triggered by `act` when it detects a `task` or `spawn_coding_agent` tool call.
  Extracts the task prompt from `state.tool_uses`, calls `SessionBridge`, registers
  the child session with `AgentRegistry`, and broadcasts `code_agent_spawned` on
  the parent session's PubSub topic so the UI shows the embedded panel.

  Routes to `:respond` so the parent loop can send a confirmation message.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  # SessionBridge lives in synapsis_agent — same app, no circular dep issue.
  alias Synapsis.Agent.{AgentRegistry, SessionBridge}

  require Logger

  @spawn_tools ~w[task spawn_coding_agent]

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, ctx) do
    case find_spawn_tool(state.tool_uses) do
      nil ->
        # Nothing to spawn — fall through to respond
        {:next, :respond, state}

      tool_use ->
        prompt = extract_prompt(tool_use)
        project_id = ctx[:project_id] || state[:project_id]
        parent_session_id = state.session_id

        spawn_and_notify(parent_session_id, project_id, prompt, state)
    end
  end

  # -- Private --

  defp find_spawn_tool(tool_uses) when is_list(tool_uses) do
    Enum.find(tool_uses, fn tu -> Map.get(tu, :name) in @spawn_tools end)
  end

  defp find_spawn_tool(_), do: nil

  defp extract_prompt(tool_use) do
    input = Map.get(tool_use, :input, %{})
    Map.get(input, "prompt") || Map.get(input, :prompt) || "Perform the requested task."
  end

  defp spawn_and_notify(parent_session_id, project_id, prompt, state) do
    opts = %{
      notify_pid: self(),
      notify_ref: parent_session_id
    }

    case SessionBridge.spawn_coding_session(project_id, prompt, opts) do
      {:ok, child_session_id} ->
        AgentRegistry.register(parent_session_id, child_session_id, prompt)

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{parent_session_id}",
          {"code_agent_spawned",
           %{
             sub_session_id: child_session_id,
             prompt: prompt,
             parent_session_id: parent_session_id
           }}
        )

        Logger.info("spawn_agent_node_spawned",
          parent_session_id: parent_session_id,
          child_session_id: child_session_id,
          prompt: String.slice(prompt, 0, 100)
        )

        confirmation =
          "\n\nI've delegated this task to a Code Agent (session `#{child_session_id}`). " <>
            "You can track its progress in the panel below."

        {:next, :respond, Map.update(state, :pending_text, confirmation, &(&1 <> confirmation))}

      {:error, reason} ->
        Logger.warning("spawn_agent_node_failed",
          parent_session_id: parent_session_id,
          reason: inspect(reason)
        )

        error_text = "\n\nFailed to spawn Code Agent: #{inspect(reason)}"

        {:next, :respond, Map.update(state, :pending_text, error_text, &(&1 <> error_text))}
    end
  end
end
