defmodule Synapsis.Voice.History do
  @moduledoc false

  alias Synapsis.Message
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Session.Store

  def audio_input(item, generation),
    do: [%{type: :committed_audio, item_id: item, connection_generation: generation}]

  def microphone_prompt(item, generation) do
    [block] = audio_input(item, generation)
    [Map.put(block, :live_microphone, true)]
  end

  def microphone_message(item, generation) do
    %{
      role: :user,
      id: "mic-" <> generation <> ":" <> item,
      content: audio_input(item, generation)
    }
  end

  def initial(messages) do
    messages
    |> Enum.take(-100)
    |> Enum.flat_map(fn message ->
      case ProviderMessages.from_host([message]) do
        {:ok, [native]} -> [Map.put(native, :id, message.id || Ecto.UUID.generate())]
        _ -> []
      end
    end)
  end

  def append(session_id, canonical, image_payloads \\ %{}) do
    with {:ok, previous} <- Store.list_turns(session_id) do
      ids = MapSet.new(previous, &(&1[:id] || &1["id"]))
      append_messages(session_id, project(session_id, canonical, image_payloads, ids))
    end
  end

  # The voice owner deduplicates by message id and serializes projected batches.
  def append_messages(_, []), do: :ok

  def append_messages(session_id, messages) do
    with {:ok, offset} <- Store.count_turns(session_id),
         {:ok, meta} <- Store.get_meta(session_id) do
      Store.commit_turns(session_id, offset, Enum.map(messages, &Message.encode/1), %{
        meta
        | updated_at: DateTime.utc_now()
      })
    end
  end

  def project(session_id, canonical, image_payloads, ids) do
    canonical
    |> Enum.with_index()
    |> Enum.reject(fn
      {%{role: :user, content: [%{live_microphone: true}]}, _} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {item, index} ->
      id = item[:id] || synthesized_id(canonical, item, index)

      if MapSet.member?(ids, id) do
        []
      else
        case message(session_id, item, id, image_payloads) do
          nil -> []
          message -> [message]
        end
      end
    end)
  end

  def save_fact(session_id, type, key, data),
    do: Synapsis.Runtime.Store.put_fact(session_id, type, key, data)

  def recovery(session_id) do
    Map.new([:voice_playback, :voice_transcript], fn source ->
      entries =
        case Synapsis.Runtime.Store.list_facts_by_identity(session_id, source) do
          {:ok, facts} -> facts
          _ -> %{}
        end

      {source, entries}
    end)
  end

  def transcript(session_id, generation, item) do
    case Synapsis.Runtime.Store.get_fact(session_id, :voice_transcript, generation <> ":" <> item) do
      {:ok, transcript} -> transcript
      _ -> nil
    end
  end

  def final_result(namespace, run_id) do
    case Synapsis.Runtime.Store.load(namespace, run_id) do
      {:ok, %{run: %{context: %{conversation: %{messages: messages}}}}} ->
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: :assistant, content: text} when is_binary(text) and text != "" ->
            String.slice(text, 0, 4_000)

          %{role: :assistant, content: blocks} when is_list(blocks) ->
            text = Enum.map_join(blocks, "\n", &(&1[:text] || ""))
            if text != "", do: String.slice(text, 0, 4_000)

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp message(session_id, item, id, image_payloads) do
    case ProviderMessages.to_host([item], image_payloads) do
      {:ok, [%{role: role, parts: [_ | _] = parts}]} ->
        %Message{
          id: id,
          session_id: session_id,
          role: if(role == :tool, do: "assistant", else: Atom.to_string(role)),
          parts: parts,
          inserted_at: DateTime.utc_now()
        }

      _ ->
        nil
    end
  end

  defp synthesized_id(canonical, item, index) do
    case item[:invocation_id] do
      id when is_binary(id) ->
        "voice-tool-" <> id

      _ ->
        # A completed assistant can lack a provider ID. Anchor its projection to
        # the canonical input or child result so later snapshots deduplicate it.
        anchor = canonical |> Enum.take(index) |> Enum.reverse() |> Enum.find_value(& &1[:id])

        digest =
          :crypto.hash(:sha256, :erlang.term_to_binary({anchor, item, index}, [:deterministic]))

        "voice-" <> Base.url_encode64(digest, padding: false)
    end
  end
end
