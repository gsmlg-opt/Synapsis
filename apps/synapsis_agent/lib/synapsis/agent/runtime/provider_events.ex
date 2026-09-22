defmodule Synapsis.Agent.Runtime.ProviderEvents do
  @moduledoc "Accumulates current Synapsis provider events into runtime events and terminal history."

  alias Backplane.AgentRuntime.Error

  def new, do: %{blocks: [], pending: %{}, completed: MapSet.new()}

  def push(state, {:text_delta, text}) when is_binary(text),
    do: {:ok, [%{type: :content_text_delta, delta: text}], append_text(state, :text, text)}

  def push(state, {:reasoning_delta, text}) when is_binary(text),
    do:
      {:ok, [%{type: :content_thinking_delta, delta: text}], append_text(state, :reasoning, text)}

  def push(state, {:provider_state, value}) when is_map(value) do
    block = %{type: :reasoning, text: "", provider_states: [value]}
    # Signed provider state contains its original reasoning payload. Keeping it
    # with the preceding reasoning block avoids replaying that text twice.
    blocks =
      case List.last(state.blocks) do
        %{type: :reasoning} = last ->
          updated = Map.update(last, :provider_states, [value], &(&1 ++ [value]))
          List.replace_at(state.blocks, -1, updated)

        _ ->
          state.blocks ++ [block]
      end

    {:ok, [], %{state | blocks: blocks}}
  end

  def push(state, {:usage, usage}) when is_map(usage) do
    usage = if is_struct(usage), do: Map.from_struct(usage), else: usage
    {:ok, [%{type: :usage_updated, usage: usage}], state}
  end

  def push(state, {:tool_call_delta, index, id, name, delta}) when is_binary(delta) do
    previous = Map.get(state.pending, index, %{id: nil, name: nil, started: false, arguments: ""})

    call = %{
      previous
      | id: id || previous.id,
        name: name || previous.name,
        arguments: previous.arguments <> delta
    }

    if MapSet.member?(state.completed, index) or
         (not is_nil(previous.id) and not is_nil(id) and previous.id != id) or
         (not is_nil(previous.name) and not is_nil(name) and previous.name != name) do
      malformed("Tool identity changed during stream")
    else
      ready = is_binary(call.id) and call.id != "" and is_binary(call.name) and call.name != ""

      events =
        cond do
          ready and not previous.started ->
            [
              %{type: :tool_call_started, tool_call: %{id: call.id, name: call.name}},
              %{type: :tool_call_arguments_delta, tool_call_id: call.id, delta: call.arguments}
            ]

          previous.started ->
            [%{type: :tool_call_arguments_delta, tool_call_id: call.id, delta: delta}]

          true ->
            []
        end

      {:ok, events, %{state | pending: Map.put(state.pending, index, %{call | started: ready})}}
    end
  end

  def push(state, {:tool_call_done, index, id, name, arguments}) when is_map(arguments) do
    pending = Map.get(state.pending, index, %{})
    id = id || pending[:id]
    name = name || pending[:name]

    if not is_binary(id) or id == "" or not is_binary(name) or name == "" or
         MapSet.member?(state.completed, index) or
         (not is_nil(pending[:id]) and pending.id != id) or
         (not is_nil(pending[:name]) and pending.name != name) or
         Enum.any?(state.blocks, &(Map.get(&1, :type) == :tool_call and &1.id == id)) do
      malformed("Malformed or duplicate tool call")
    else
      call = %{type: :tool_call, id: id, name: name, arguments: arguments}

      {:ok, [%{type: :tool_call_completed, tool_call: Map.delete(call, :type)}],
       %{
         state
         | blocks: state.blocks ++ [call],
           pending: Map.delete(state.pending, index),
           completed: MapSet.put(state.completed, index)
       }}
    end
  end

  def push(_state, {:error, error}), do: {:error, error}
  def push(state, :ignore), do: {:ok, [], state}
  def push(_, _), do: malformed("Unsupported or malformed host provider event")

  def finish(%{pending: pending, blocks: blocks}) when map_size(pending) == 0,
    do: {:ok, %{type: :response_completed, message: %{role: :assistant, content: blocks}}}

  def finish(_), do: malformed("Provider ended with an incomplete tool call")

  defp append_text(state, type, text) do
    blocks =
      case List.last(state.blocks) do
        %{type: :reasoning, provider_states: [_ | _]} when type == :reasoning ->
          state.blocks ++ [%{type: type, text: text}]

        %{type: ^type, text: previous} = last ->
          List.replace_at(state.blocks, -1, %{last | text: previous <> text})

        _ ->
          state.blocks ++ [%{type: type, text: text}]
      end

    %{state | blocks: blocks}
  end

  defp malformed(message), do: {:error, Error.new(:malformed_result, message)}
end
