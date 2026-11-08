defmodule Synapsis.SessionDirectory.Projection do
  @moduledoc false

  alias Synapsis.{Message, Part.Text}
  alias Synapsis.Session.{EventReply, ReadSnapshot}
  alias Synapsis.SessionDirectory.Projection.PortSession

  @max_bytes 1_048_576

  def enrich(entries, input, node, deadline) do
    if Enum.any?(entries, & &1.enrich?) do
      PortSession.run(node, deadline, fn broker ->
        with {:ok, enriched, _broker} <- project(entries, input, broker), do: {:ok, enriched}
      end)
    else
      {:ok, entries}
    end
  end

  def project(entries, input, broker) do
    targets = Enum.filter(entries, & &1.enrich?)

    if targets == [] do
      {:ok, entries, broker}
    else
      options = %{
        includeDerivedTitles: Map.get(input, "include_derived_titles", false),
        includeLastMessage: Map.get(input, "include_last_message", false)
      }

      with {:ok, probes} <- initial_probes(targets, options),
           {:ok, first, broker} <- PortSession.project(broker, dtos(probes), options),
           {:ok, probes, widened?} <- widen(probes, first),
           {:ok, candidates, broker} <-
             final_candidates(broker, probes, options, first, widened?) do
        enriched =
          Enum.zip(targets, candidates)
          |> Map.new(fn {entry, candidate} ->
            row =
              entry.row
              |> optional(:derived_title, candidate["derivedTitle"])
              |> optional(:last_message_preview, candidate["lastMessagePreview"])

            {entry.row.id, row}
          end)

        {:ok, Enum.map(entries, &%{&1 | row: Map.get(enriched, &1.row.id, &1.row)}), broker}
      end
    end
  end

  defp initial_probes(targets, options) do
    Enum.reduce_while(targets, {:ok, []}, fn entry, {:ok, probes} ->
      with {:ok, head} <- probe(entry.handle, :asc, options.includeDerivedTitles, 20),
           {:ok, tail} <- probe(entry.handle, :desc, options.includeLastMessage, 20) do
        {:cont, {:ok, [%{entry: entry, head: head, tail: tail} | probes]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, probes} -> {:ok, Enum.reverse(probes)}
      error -> error
    end
  end

  defp widen(probes, candidates) do
    Enum.zip(probes, candidates)
    |> Enum.reduce_while({:ok, [], false}, fn {item, candidate}, {:ok, acc, any?} ->
      head? = candidate["needsHead"] and item.head.has_more
      tail? = candidate["needsTail"] and item.tail.has_more

      with {:ok, head} <- wider(item, :head, :asc, head?),
           {:ok, tail} <- wider(item, :tail, :desc, tail?) do
        {:cont, {:ok, [%{item | head: head, tail: tail} | acc], any? or head? or tail?}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, widened?} -> {:ok, Enum.reverse(items), widened?}
      error -> error
    end
  end

  defp wider(item, key, _order, false), do: {:ok, Map.fetch!(item, key)}
  defp wider(item, _key, order, true), do: probe(item.entry.handle, order, true, 100)

  defp probe(_handle, _order, false, _limit),
    do: {:ok, %{turns: [], has_more: false, truncated: false}}

  defp probe(handle, order, true, limit),
    do: ReadSnapshot.read_page(handle, order: order, limit: limit, max_bytes: @max_bytes)

  defp final_candidates(broker, probes, options, _first, true) do
    PortSession.project(broker, dtos(probes), options)
  end

  defp final_candidates(broker, _probes, _options, first, false), do: {:ok, first, broker}

  defp dtos(probes) do
    Enum.map(probes, fn item ->
      %{
        # Session identity is real. Synapsis title is deliberately not a source
        # label/displayName/subject, so source derives from eligible user text.
        entry: %{sessionId: item.entry.row.id},
        head: turns(item.head.turns),
        tail: turns(item.tail.turns)
      }
    end)
  end

  # Preserve raw durable data. EventReply is the existing narrow host display
  # policy and recognizes its own stamp; its returned copy is never persisted.
  def turns(turns) do
    Enum.flat_map(turns, fn %{turn: raw} ->
      message = %Message{
        role: field(raw, :role),
        parts: Enum.map(field(raw, :parts) || [], &display_part/1),
        reply_presentation: field(raw, :reply_presentation)
      }

      case EventReply.display_message(message) do
        nil ->
          []

        displayed ->
          dto = %{
            role: normalize_role(displayed.role),
            content: Enum.map(displayed.parts, &source_part/1)
          }

          [optional(dto, :provenance, provenance(field(raw, :input_provenance)))]
      end
    end)
  end

  defp display_part(part) do
    if field(part, :type) == "text",
      do: %Text{content: field(part, :text) || ""},
      else: part
  end

  defp source_part(%Text{content: text}), do: %{type: "text", text: text}

  defp source_part(part) do
    case field(part, :type) do
      "tool_result" ->
        %{type: "toolResult", toolCallId: field(part, :tool_use_id)}

      "tool_use" ->
        %{type: "toolCall", id: field(part, :id), name: field(part, :name)}

      "reasoning" ->
        # Reasoning signatures are not source Text.textSignature/phase facts.
        %{type: "thinking", thinking: field(part, :text) || field(part, :content) || ""}

      "image" ->
        %{type: "image", mimeType: field(part, :media_type)}

      _ ->
        %{type: "unknown"}
    end
  end

  defp provenance(value) when is_map(value) do
    case field(value, :kind) do
      kind when kind in ["external_user", "inter_session", "internal_system"] ->
        # source_session_id is a host UUID, not an OpenClaw sourceSessionKey.
        %{kind: kind} |> optional(:sourceTool, field(value, :source_tool))

      _ ->
        nil
    end
  end

  defp provenance(_), do: nil
  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role), do: role
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
