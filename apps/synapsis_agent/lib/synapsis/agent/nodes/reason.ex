defmodule Synapsis.Agent.Nodes.Reason do
  @moduledoc """
  LLM reasoning step for the conversational loop.

  Requests the Worker to start a provider stream and pauses until the stream
  completes. Equivalent to LLMStream in the coding loop but named for the
  conversational context where the LLM "reasons" about the user's intent.

  On resume, propagates stream accumulator into workflow state so the Act node
  can inspect the response.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  import Synapsis.Agent.Nodes.Helpers, only: [worker_pid: 1]

  require Logger

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()} | {:wait, map()}
  def run(state, ctx) do
    if state[:awaiting_stream] do
      cond do
        ctx[:stream_error] ->
          Logger.warning("reason_stream_error", reason: inspect(ctx[:stream_error]))

          new_state =
            state
            |> Map.delete(:awaiting_stream)
            |> Map.put(:stream_error, ctx[:stream_error])

          {:next, :error, new_state}

        ctx[:stream_acc] ->
          acc = ctx[:stream_acc]

          new_state =
            %{
              state
              | pending_text: acc.pending_text,
                pending_tool_use: acc.pending_tool_use,
                pending_tool_input: acc.pending_tool_input,
                pending_reasoning: acc.pending_reasoning,
                tool_uses: acc.tool_uses
            }
            |> Map.delete(:awaiting_stream)
            |> Map.delete(:request)

          {:next, :default, new_state}

        true ->
          {:next, :default, Map.delete(state, :awaiting_stream)}
      end
    else
      if pid = worker_pid(state.session_id) do
        send(pid, {:node_request, :start_stream, state.request})
      end

      {:wait, Map.put(state, :awaiting_stream, true)}
    end
  end
end
