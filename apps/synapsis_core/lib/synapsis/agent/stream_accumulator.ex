defmodule Synapsis.Agent.StreamAccumulator do
  @moduledoc """
  Pure function for accumulating provider stream events into pending state.
  No GenServer, no side effects — just data transformation.

  Extracted from Session.Worker.handle_stream_event/2.
  """

  @type acc :: %{
          pending_text: String.t(),
          pending_tool_use: map() | nil,
          pending_tool_input: String.t(),
          pending_reasoning: String.t(),
          tool_uses: [Synapsis.Part.ToolUse.t()]
        }

  @doc """
  Accumulates a single stream event into the accumulator state.
  Returns `{broadcasts, new_acc}` where broadcasts is a list of
  `{event_name, payload}` tuples to be sent via PubSub.
  """
  @spec accumulate(term(), acc()) :: {[{String.t(), map()}], acc()}
  def accumulate({:text_delta, text}, acc) do
    {[{"text_delta", %{text: text}}], %{acc | pending_text: acc.pending_text <> text}}
  end

  def accumulate(:text_start, acc), do: {[], acc}

  def accumulate({:tool_use_start, name, id}, acc) do
    broadcasts = [{"tool_use", %{tool: name, tool_use_id: id}}]
    new_acc = %{acc | pending_tool_use: %{tool: name, tool_use_id: id}, pending_tool_input: ""}
    {broadcasts, new_acc}
  end

  def accumulate({:tool_input_delta, json}, acc) do
    {[], %{acc | pending_tool_input: acc.pending_tool_input <> json}}
  end

  def accumulate({:tool_use_complete, name, args}, acc) do
    tool_use = %Synapsis.Part.ToolUse{
      tool: name,
      tool_use_id: "tu_#{System.unique_integer([:positive])}",
      input: args,
      status: :pending
    }

    {[], %{acc | tool_uses: acc.tool_uses ++ [tool_use]}}
  end

  def accumulate(:content_block_stop, acc) do
    case acc.pending_tool_use do
      nil ->
        {[], acc}

      %{tool: name, tool_use_id: id} ->
        input =
          case Jason.decode(acc.pending_tool_input) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        tool_use = %Synapsis.Part.ToolUse{
          tool: name,
          tool_use_id: id,
          input: input,
          status: :pending
        }

        new_acc = %{
          acc
          | pending_tool_use: nil,
            pending_tool_input: "",
            tool_uses: acc.tool_uses ++ [tool_use]
        }

        {[], new_acc}
    end
  end

  def accumulate(:reasoning_start, acc), do: {[], acc}

  def accumulate({:reasoning_delta, text}, acc) do
    {[{"reasoning", %{text: text}}], %{acc | pending_reasoning: acc.pending_reasoning <> text}}
  end

  def accumulate(:message_start, acc), do: {[], acc}
  def accumulate({:message_delta, _delta}, acc), do: {[], acc}
  def accumulate(:done, acc), do: {[], acc}
  def accumulate(:ignore, acc), do: {[], acc}

  def accumulate({:error, error}, acc) do
    error_msg = if is_map(error), do: error["message"] || "provider error", else: "provider error"
    {[{"error", %{message: error_msg}}], acc}
  end

  @doc """
  Returns a fresh accumulator state with all pending fields zeroed.
  """
  @spec new() :: acc()
  def new do
    %{
      pending_text: "",
      pending_tool_use: nil,
      pending_tool_input: "",
      pending_reasoning: "",
      tool_uses: []
    }
  end
end
