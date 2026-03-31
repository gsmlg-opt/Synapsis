defmodule Synapsis.Agent.Nodes.CompactContext do
  @moduledoc """
  Graph node that checks session token count and triggers compaction if over threshold (AI-5).

  Positioned between `receive_message` and `build_prompt` in the conversational loop.
  Compaction is silent but broadcasts a notification via PubSub.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id
    agent_config = state.agent_config || %{}
    model = agent_config[:model]

    # Delegate to existing compactor — it handles threshold checking
    case Synapsis.Session.Compactor.maybe_compact(session_id, model) do
      {:ok, :no_compaction_needed} ->
        {:next, :default, state}

      {:ok, %{removed: removed, kept: kept, summary_tokens: summary_tokens}} ->
        Logger.info("session_compacted",
          session_id: session_id,
          messages_removed: removed,
          messages_kept: kept,
          summary_tokens: summary_tokens
        )

        metadata = %{
          messages_removed: removed,
          messages_kept: kept,
          summary_tokens: summary_tokens
        }

        # Telemetry (AI-5.6)
        :telemetry.execute(
          [:synapsis_agent, :compaction, :complete],
          %{removed: removed, kept: kept, summary_tokens: summary_tokens},
          %{session_id: session_id}
        )

        # Broadcast session_compacted event (AI-5.6)
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {:session_compacted, session_id, metadata}
        )

        # Broadcast system_message for inline chat notification (RD-2)
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {:system_message,
           %{
             type: :compaction,
             text:
               "Context compacted: #{removed} messages summarized, #{kept} recent messages preserved",
             metadata: metadata
           }}
        )

        {:next, :default, state}

      {:error, reason} ->
        Logger.warning("compaction_failed", session_id: session_id, reason: inspect(reason))
        # Don't block the pipeline on compaction failure
        {:next, :default, state}
    end
  end
end
