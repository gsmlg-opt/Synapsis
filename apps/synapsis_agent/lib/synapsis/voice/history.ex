defmodule Synapsis.Voice.History do
  @moduledoc false

  alias Synapsis.Message
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Session.Store

  def audio_input(item, generation),
    do: [%{type: :committed_audio, item_id: item, connection_generation: generation}]

  def initial(session_id) do
    session_id
    |> Synapsis.Sessions.get_recent_messages(limit: 100)
    |> Enum.flat_map(fn message ->
      case ProviderMessages.from_host([message]) do
        {:ok, [native]} -> [Map.put(native, :id, message.id || Ecto.UUID.generate())]
        _ -> []
      end
    end)
  end

  def append(session_id, canonical) do
    with {:ok, offset} <- Store.count_turns(session_id),
         {:ok, meta} <- Store.get_meta(session_id),
         {:ok, previous} <- Store.list_turns(session_id) do
      ids = MapSet.new(previous, &(&1[:id] || &1["id"]))

      turns =
        canonical
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} ->
          id = item[:id] || synthesized_id(canonical, item, index)

          if MapSet.member?(ids, id) do
            []
          else
            case message(session_id, item, id) do
              nil -> []
              message -> [Message.encode(message)]
            end
          end
        end)

      if turns == [] do
        :ok
      else
        Store.commit_turns(session_id, offset, turns, %{meta | updated_at: DateTime.utc_now()})
      end
    end
  end

  def save_fact(session_id, type, key, data),
    do: Synapsis.Runtime.Store.put_fact(session_id, type, key, data)

  def recovery(session_id) do
    Map.new([:voice_playback, :voice_transcript], fn source ->
      entries =
        case Synapsis.Runtime.Store.list_facts(session_id, source) do
          {:ok, pairs} ->
            Map.new(pairs, fn {key, value} ->
              identity =
                key |> String.split("/") |> List.last() |> Base.url_decode64!(padding: false)

              {identity, value}
            end)

          _ ->
            %{}
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

  defp message(session_id, item, id) do
    case ProviderMessages.to_host([item]) do
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
