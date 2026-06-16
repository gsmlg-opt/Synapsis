defmodule Synapsis.Agent.Nodes.ProcessResponse do
  @moduledoc "Flushes accumulated text/tools to DB via ResponseFlusher. Routes based on tool presence."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  alias Synapsis.Agent.ResponseFlusher
  alias Synapsis.{Message, Part}

  # An iteration that produced no answer text and no tool call is a degenerate
  # "empty completion" (e.g. the provider returned only reasoning, or its output
  # could not be parsed). Retry the model a bounded number of times, then surface
  # a visible notice rather than letting the loop go idle with no answer.
  @default_max_empty_retries 1

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id

    # Flush accumulated content to DB
    acc = %{
      pending_text: Map.get(state, :pending_text, ""),
      pending_tool_use: Map.get(state, :pending_tool_use),
      pending_tool_input: Map.get(state, :pending_tool_input, ""),
      pending_reasoning: Map.get(state, :pending_reasoning, ""),
      pending_reasoning_signature: Map.get(state, :pending_reasoning_signature, ""),
      tool_uses: Map.get(state, :tool_uses, [])
    }

    flushed = ResponseFlusher.flush(session_id, acc)

    new_state =
      Map.merge(state, %{
        pending_text: flushed.pending_text,
        pending_tool_use: flushed.pending_tool_use,
        pending_tool_input: flushed.pending_tool_input,
        pending_reasoning: flushed.pending_reasoning,
        pending_reasoning_signature: flushed.pending_reasoning_signature,
        iteration_activity: %{
          text_emitted: acc.pending_text != "",
          tool_calls_emitted: length(acc.tool_uses),
          tool_results_received: 0
        }
      })

    cond do
      acc.tool_uses != [] ->
        {:next, :has_tools, Map.put(new_state, :empty_completion_retries, 0)}

      acc.pending_text != "" ->
        {:next, :no_tools, Map.put(new_state, :empty_completion_retries, 0)}

      true ->
        handle_empty_completion(session_id, new_state)
    end
  end

  defp handle_empty_completion(session_id, state) do
    retries = Map.get(state, :empty_completion_retries, 0)

    max_retries =
      Application.get_env(
        :synapsis_core,
        :max_empty_completion_retries,
        @default_max_empty_retries
      )

    if retries < max_retries do
      Logger.warning("empty_completion_retry", session_id: session_id, attempt: retries + 1)
      # Re-run the model with the same context; bounded by the retry counter.
      {:next, :retry, Map.put(state, :empty_completion_retries, retries + 1)}
    else
      Logger.warning("empty_completion_surfaced", session_id: session_id)
      persist_empty_notice(session_id)
      {:next, :no_tools, Map.put(state, :empty_completion_retries, 0)}
    end
  end

  defp persist_empty_notice(session_id) do
    Message.append(session_id, %Message{
      role: "system",
      parts: [
        %Part.Text{
          content:
            "The model finished without producing an answer (it returned only reasoning, " <>
              "or its output could not be parsed). Try resending your message."
        }
      ],
      token_count: 0
    })
  end
end
