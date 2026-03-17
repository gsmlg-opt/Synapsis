defmodule Synapsis.Agent.Nodes.BuildPrompt do
  @moduledoc "Loads messages from DB, builds provider request via MessageBuilder."
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.{Repo, Message}
  import Ecto.Query
  require Logger

  @impl true
  def run(state, ctx) do
    session_id = state.session_id
    agent_config = state.agent_config
    provider = ctx[:provider] || agent_config[:provider] || "anthropic"

    # Compact if needed
    Synapsis.Session.Compactor.maybe_compact(session_id, ctx[:model] || agent_config[:model])

    # Load messages from DB
    messages =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], asc: m.inserted_at)
      |> Repo.all()

    # Build failure context for injection
    prompt_context = Synapsis.PromptBuilder.build_prompt_context(session_id)

    # Build the request
    request =
      Synapsis.MessageBuilder.build_request(
        messages,
        agent_config,
        provider,
        prompt_context
      )

    new_state = %{state | messages: messages, user_input: nil}
    new_state = Map.put(new_state, :request, request)

    {:next, :default, new_state}
  end
end
