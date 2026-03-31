defmodule Synapsis.Agent.Nodes.BuildPrompt do
  @moduledoc """
  Loads messages from DB, builds provider request via MessageBuilder.

  Uses the full context assembly pipeline (AI-2) to build the system prompt
  with identity files, skills manifest, memory context, and project context.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Message
  alias Synapsis.Agent.ContextBuilder
  require Logger

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, ctx) do
    session_id = state.session_id
    agent_config = state.agent_config
    provider = ctx[:provider] || agent_config[:provider] || "anthropic"

    # Load messages from DB
    messages = Message.list_by_session(session_id)

    # Extract latest user message for memory search
    user_message = extract_latest_user_message(messages)

    # Build full system prompt via ContextBuilder (AI-2)
    system_prompt =
      ContextBuilder.build_system_prompt(:coding, [
        {:project_id, agent_config[:project_id]},
        {:session_id, session_id},
        {:user_message, user_message},
        {:agent_config, agent_config}
      ])

    # Build failure context and append
    failure_context = Synapsis.PromptBuilder.build_failure_context(session_id)

    full_prompt =
      if failure_context do
        system_prompt <> "\n\n" <> failure_context
      else
        system_prompt
      end

    # Override agent config with assembled system prompt
    enriched_config = Map.put(agent_config, :system_prompt, full_prompt)

    # Build the request
    request =
      Synapsis.MessageBuilder.build_request(
        messages,
        enriched_config,
        provider
      )

    new_state = %{state | messages: messages, user_input: nil}
    new_state = Map.put(new_state, :request, request)

    {:next, :default, new_state}
  end

  defp extract_latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", parts: parts} when is_list(parts) ->
        Enum.find_value(parts, fn
          %Synapsis.Part.Text{content: c} when is_binary(c) -> c
          _ -> nil
        end)

      _ ->
        nil
    end)
  end
end
