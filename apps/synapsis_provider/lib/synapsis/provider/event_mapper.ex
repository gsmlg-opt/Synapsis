defmodule Synapsis.Provider.EventMapper do
  @moduledoc "Maps canonical Backplane stream events into Synapsis host events."

  alias Backplane.AiProtocol.{ContentBlock, ProviderState, StreamEvent}
  alias Synapsis.Provider.ToolName

  def map_event(%StreamEvent{type: :text_delta, text: text}), do: {:text_delta, text}
  def map_event(%StreamEvent{type: :reasoning_delta, text: text}), do: {:reasoning_delta, text}

  def map_event(%StreamEvent{type: :tool_call_start} = event) do
    {:tool_call_delta, event.index, event.call_id, decode_name(event.name), ""}
  end

  def map_event(%StreamEvent{type: :tool_call_delta} = event) do
    {:tool_call_delta, event.index, event.call_id, decode_name(event.name),
     event.arguments_delta || ""}
  end

  def map_event(%StreamEvent{type: :tool_call_done} = event) do
    {:tool_call_done, event.index, event.call_id, decode_name(event.name), event.content}
  end

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
end
