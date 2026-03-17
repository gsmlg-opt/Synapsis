defmodule Synapsis.Agent.Nodes.LLMStream do
  @moduledoc """
  Starts provider stream and pauses. Stream events are accumulated externally
  (via event_handler) using StreamAccumulator. Resumes when stream completes.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  alias Synapsis.Session.Stream, as: SessionStream
  require Logger

  @impl true
  def run(state, ctx) do
    provider_config = state.provider_config
    provider = ctx[:provider] || state.agent_config[:provider] || "anthropic"

    case state[:stream_completed] do
      true ->
        # Stream already completed (resumed after streaming) -- proceed
        new_state =
          state
          |> Map.delete(:stream_completed)
          |> Map.delete(:request)

        {:next, :default, new_state}

      _ ->
        request = state[:request]

        # Start streaming -- pause and wait for completion
        case SessionStream.start_stream(request, provider_config, provider) do
          {:ok, ref} ->
            new_state = Map.put(state, :stream_ref, ref)
            {:wait, new_state}

          {:error, reason} ->
            Logger.warning("llm_stream_failed", reason: inspect(reason))
            new_state = Map.put(state, :stream_error, reason)
            {:next, :error, new_state}
        end
    end
  end
end
