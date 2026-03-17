defmodule Synapsis.Agent.Nodes.LLMStream do
  @moduledoc """
  Requests Worker to start provider stream. Pauses while streaming.
  Resumes when Worker sends stream_acc or stream_error via Runner.resume/2.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  @impl true
  def run(state, ctx) do
    if state[:awaiting_stream] do
      # Resumed after stream completed — read accumulated data from ctx
      cond do
        ctx[:stream_error] ->
          Logger.warning("llm_stream_error", reason: inspect(ctx[:stream_error]))

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
          new_state = Map.delete(state, :awaiting_stream)
          {:next, :default, new_state}
      end
    else
      # Request Worker to start streaming
      if pid = worker_pid(state.session_id) do
        send(pid, {:node_request, :start_stream, state.request})
      end

      {:wait, Map.put(state, :awaiting_stream, true)}
    end
  end

  defp worker_pid(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
