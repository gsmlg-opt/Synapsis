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
          pending_tool_calls: map(),
          pending_reasoning: String.t(),
          pending_reasoning_signature: String.t(),
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

  def accumulate({:tool_call_delta, index, id, name, arguments}, acc) do
    pending = Map.get(acc.pending_tool_calls, index, new_pending_tool_call())

    updated =
      pending
      |> maybe_put(:tool_use_id, id)
      |> maybe_put(:tool, name)
      |> append_tool_arguments(arguments)

    {broadcasts, updated} = maybe_broadcast_tool_start(updated)

    new_acc = %{
      acc
      | pending_tool_calls: Map.put(acc.pending_tool_calls, index, updated)
    }

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

  def accumulate({:reasoning_signature_delta, signature}, acc) do
    {[], %{acc | pending_reasoning_signature: acc.pending_reasoning_signature <> signature}}
  end

  def accumulate(:message_start, acc), do: {[], acc}
  def accumulate({:message_delta, _delta}, acc), do: {[], acc}
  def accumulate(:done, acc), do: {[], finalize_pending_tools(acc)}
  def accumulate(:ignore, acc), do: {[], acc}

  def accumulate({:error, error}, acc) do
    error_msg = if is_map(error), do: error["message"] || "provider error", else: "provider error"
    {[{"error", %{message: error_msg}}], acc}
  end

  # Finalizes pending tool uses into tool_uses when content_block_stop was missed.
  # Some Anthropic-compatible proxies omit content_block_stop for the last tool.
  defp finalize_pending_tools(acc) do
    acc
    |> finalize_pending_tool()
    |> finalize_pending_openai_tool_calls()
  end

  defp finalize_pending_tool(%{pending_tool_use: nil} = acc), do: acc

  defp finalize_pending_tool(%{pending_tool_use: %{tool: name, tool_use_id: id}} = acc) do
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

    %{
      acc
      | pending_tool_use: nil,
        pending_tool_input: "",
        tool_uses: acc.tool_uses ++ [tool_use]
    }
  end

  defp finalize_pending_openai_tool_calls(%{pending_tool_calls: pending_tool_calls} = acc)
       when map_size(pending_tool_calls) == 0 do
    acc
  end

  defp finalize_pending_openai_tool_calls(%{pending_tool_calls: pending_tool_calls} = acc) do
    tool_uses =
      pending_tool_calls
      |> Enum.sort_by(fn {index, _tool_call} -> index end)
      |> Enum.flat_map(fn {_index, tool_call} ->
        case tool_call do
          %{tool: name, tool_use_id: id, input: input} when is_binary(name) and is_binary(id) ->
            [
              %Synapsis.Part.ToolUse{
                tool: name,
                tool_use_id: id,
                input: decode_tool_input(input),
                status: :pending
              }
            ]

          _ ->
            []
        end
      end)

    %{acc | pending_tool_calls: %{}, tool_uses: acc.tool_uses ++ tool_uses}
  end

  defp decode_tool_input(input) do
    case Jason.decode(input || "") do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
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
      pending_tool_calls: %{},
      pending_reasoning: "",
      pending_reasoning_signature: "",
      tool_uses: []
    }
  end

  defp new_pending_tool_call, do: %{tool: nil, tool_use_id: nil, input: "", broadcasted: false}

  defp maybe_put(tool_call, _key, nil), do: tool_call
  defp maybe_put(tool_call, key, value), do: Map.put(tool_call, key, value)

  defp append_tool_arguments(tool_call, arguments) when is_binary(arguments) do
    Map.update!(tool_call, :input, &(&1 <> arguments))
  end

  defp append_tool_arguments(tool_call, _arguments), do: tool_call

  defp maybe_broadcast_tool_start(%{broadcasted: false, tool: tool, tool_use_id: id} = tool_call)
       when is_binary(tool) and is_binary(id) do
    {[{"tool_use", %{tool: tool, tool_use_id: id}}], %{tool_call | broadcasted: true}}
  end

  defp maybe_broadcast_tool_start(tool_call), do: {[], tool_call}
end
