defmodule Synapsis.Provider.EventMapper do
  @moduledoc "Maps canonical Backplane stream events into Synapsis host events."

  alias Backplane.AiProtocol.{ContentBlock, Error, ProviderState, StreamEvent, ToolCall}
  alias Synapsis.Provider.ToolName

  @doc "Maps a canonical event and restores request-local tool-name aliases."
  def map_event(event, aliases) when is_map(aliases) do
    event
    |> map_event()
    |> restore_tool_aliases(aliases)
  end

  def map_event(%StreamEvent{resolved_model: model} = event)
      when is_binary(model) and model != "" do
    mapped = map_event(%{event | resolved_model: nil})
    events = if mapped == :ignore, do: [], else: [mapped]
    {:events, [{:resolved_model, model} | events]}
  end

  def map_event(%StreamEvent{type: :text_delta, text: text}), do: {:text_delta, text}
  def map_event(%StreamEvent{type: :reasoning_delta, text: text}), do: {:reasoning_delta, text}

  def map_event(%StreamEvent{type: :tool_call_start} = event) do
    {:tool_call_delta, event.index, event.call_id, decode_name(event.name), ""}
  end

  def map_event(%StreamEvent{type: :tool_call_delta} = event) do
    {:tool_call_delta, event.index, event.call_id, decode_name(event.name),
     event.arguments_delta || ""}
  end

  def map_event(
        %StreamEvent{
          type: :tool_call_done,
          content: %ContentBlock{type: :tool_call, tool_call: %ToolCall{} = call}
        } = event
      ),
      do: completed_call(event, call)

  def map_event(%StreamEvent{type: :tool_call_done, content: %ToolCall{} = call} = event),
    do: completed_call(event, call)

  def map_event(%StreamEvent{type: :tool_call_done, content: content} = event)
      when is_map(content) and not is_struct(content) do
    {:tool_call_done, event.index, event.call_id, decode_name(event.name), event.content}
  end

  def map_event(%StreamEvent{type: :tool_call_done}),
    do: Error.invalid("Malformed provider tool completion")

  def map_event(%StreamEvent{type: :provider_state, provider_state: state}) do
    {:provider_state, provider_state_map(state)}
  end

  def map_event(%StreamEvent{type: :content, content: %ContentBlock{type: :text, text: text}}),
    do: {:text_delta, text}

  def map_event(%StreamEvent{type: :content, content: %ContentBlock{type: type}}) do
    {:error,
     Backplane.AiProtocol.Error.incompatible!("Unsupported provider output content: #{type}")}
  end

  def map_event(%StreamEvent{type: :content}),
    do: {:error, Backplane.AiProtocol.Error.incompatible!("Unsupported provider output content")}

  def map_event(%StreamEvent{type: :usage, usage: usage}), do: {:usage, usage}
  def map_event(%StreamEvent{type: :terminal}), do: :ignore
  def map_event(%StreamEvent{type: :error, error: error}), do: {:error, error}
  def map_event(_event), do: :ignore

  defp completed_call(event, call) do
    with {:ok, call} <- ToolCall.new(call),
         true <- event.call_id in [nil, call.id] and event.name in [nil, call.name],
         {:ok, arguments} <- completed_arguments(call.raw_arguments) do
      {:tool_call_done, event.index, call.id, decode_name(call.name), arguments}
    else
      false -> Error.invalid("Provider tool completion identity conflicts with its event")
      {:error, _} = error -> error
    end
  end

  defp completed_arguments({:custom, input}), do: {:ok, input}
  defp completed_arguments({:structured, input}), do: {:ok, input}

  defp completed_arguments({:json, input}) do
    case Jason.decode(input) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      _ -> Error.invalid("Provider function arguments must be a JSON object")
    end
  end

  defp decode_name(nil), do: nil
  defp decode_name(name), do: ToolName.decode(name)

  defp provider_state_map(%ProviderState{} = state) do
    %{
      "source_profile" => state.source_profile,
      "source_protocol" => state.source_protocol,
      "kind" => state.kind,
      "affinity" => affinity_map(state.affinity),
      "payload" => state.payload,
      "payload_reference" => state.payload_reference,
      "constraints" => state.constraints || %{},
      "extensions" => state.extensions || %{}
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp affinity_map(affinity) do
    %{
      "profile" => affinity.profile,
      "protocol" => affinity.protocol,
      "endpoint" => affinity.endpoint,
      "account" => affinity.account,
      "workspace" => affinity.workspace,
      "model" => affinity.model
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp restore_tool_aliases({:tool_call_delta, index, id, name, args}, aliases) do
    name = if is_nil(name), do: nil, else: ToolName.decode(name, aliases)
    {:tool_call_delta, index, id, name, args}
  end

  defp restore_tool_aliases({:tool_call_done, index, id, name, content}, aliases) do
    name = if is_nil(name), do: nil, else: ToolName.decode(name, aliases)
    {:tool_call_done, index, id, name, content}
  end

  defp restore_tool_aliases({:events, events}, aliases),
    do: {:events, Enum.map(events, &restore_tool_aliases(&1, aliases))}

  defp restore_tool_aliases(event, _aliases), do: event
end
