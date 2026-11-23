defmodule Synapsis.Voice.Sync do
  @moduledoc false

  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Provider.Realtime.Protocol

  def new, do: %{items: [], seen: MapSet.new(), pending: %{}, calls: MapSet.new()}

  def stage(sync, messages, generation, confirmed) do
    Enum.reduce(messages, {[], sync}, fn message, {events, sync} ->
      case project(message, generation, sync, confirmed) do
        {:existing, item} ->
          {events, remember(sync, item)}

        {:new, key, event} ->
          if MapSet.member?(sync.seen, key) do
            {events, sync}
          else
            sync = %{
              sync
              | seen: MapSet.put(sync.seen, key),
                pending: Map.put(sync.pending, event.item.id, key),
                items: sync.items ++ [event.item.id]
            }

            {[event | events], sync}
          end

        :skip ->
          {events, sync}
      end
    end)
    |> then(fn {events, sync} -> {Enum.reverse(events), sync} end)
  end

  def acknowledge(sync, id), do: %{sync | pending: Map.delete(sync.pending, id)}

  def completed(sync, output, calls) do
    sync =
      Enum.reduce(output, sync, fn
        %{"id" => id}, acc when is_binary(id) -> remember(acc, id)
        _, acc -> acc
      end)

    %{sync | calls: Enum.reduce(calls, sync.calls, &MapSet.put(&2, &1.id))}
  end

  defp remember(sync, item) do
    if item in sync.items, do: sync, else: %{sync | items: sync.items ++ [item]}
  end

  defp project(
         %{
           role: :user,
           content: [%{type: :committed_audio, item_id: item, connection_generation: generation}]
         },
         generation,
         _sync,
         _confirmed
       ),
       do: {:existing, item}

  defp project(
         %{
           role: :user,
           content: [%{type: :committed_audio, item_id: item, connection_generation: previous}]
         },
         _,
         _,
         confirmed
       ) do
    key = previous <> ":" <> item

    case get_in(confirmed, [:voice_transcript, key]) do
      transcript when is_binary(transcript) and transcript != "" ->
        text_event({:recovered_audio, key}, "[Prior microphone transcript] " <> transcript)

      _ ->
        :skip
    end
  end

  defp project(
         %{
           role: :assistant,
           content: [
             %{
               type: :spoken_audio,
               text: text,
               item_id: item,
               content_index: index,
               connection_generation: previous
             }
           ]
         },
         generation,
         _,
         confirmed
       )
       when previous != generation do
    key = previous <> ":" <> item <> ":" <> Integer.to_string(index)

    case get_in(confirmed, [:voice_playback, key]) do
      %{generated: true, interrupted: false} ->
        text_event(
          {:recovered_playback, key},
          "[Prior assistant speech played to the user] " <> text
        )

      _ ->
        :skip
    end
  end

  defp project(%{role: :user, content: content} = message, _, _, _) do
    key = get_in(message, [:host_feedback, "id"]) || message[:id]

    text =
      if is_binary(content),
        do: content,
        else: Enum.map_join(content, "\n", fn block -> block[:text] || "" end)

    if is_binary(key) and text != "" do
      text_event({:text, key}, text)
    else
      :skip
    end
  end

  defp project(%{role: :tool, tool_call_id: id, result: result} = message, _, sync, _) do
    if MapSet.member?(sync.calls, id) do
      text =
        case ProviderMessages.tool_result_text(result, message[:name]) do
          {:ok, text} -> text
          _ -> "The tool result could not be represented as voice-session text."
        end

      key = {:result, message[:invocation_id] || id}
      {:new, key, Protocol.output_item(item_id(key), id, String.slice(text, 0, 32_000))}
    else
      :skip
    end
  end

  defp project(_, _, _, _), do: :skip

  defp text_event(key, text), do: {:new, key, Protocol.text_item(item_id(key), text)}

  defp item_id(key) do
    "item_" <>
      (key
       |> :erlang.term_to_binary([:deterministic])
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.url_encode64(padding: false)
       |> binary_part(0, 24))
  end
end
