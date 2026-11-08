defmodule Synapsis.SessionDirectory.History.DTO do
  @moduledoc false

  alias Synapsis.{Message, Part.Text}
  alias Synapsis.Session.EventReply

  # One durable part maps to one content block. EventReply indexes therefore
  # refer to this unfiltered array, including reasoning and tool blocks.
  def row(%{index: index, turn: raw}, ordinal) do
    parts = field(raw, :parts) || []
    role = normalize_role(field(raw, :role))
    content = Enum.map(parts, &part/1)

    source =
      %{"role" => role, "content" => content, "__openclaw" => %{"seq" => ordinal}}
      |> put_meta_id(field(raw, :id))
      |> optional("timestamp", timestamp(field(raw, :inserted_at)))
      |> optional("provenance", provenance(field(raw, :input_provenance)))
      |> tool_envelope(role, content)

    %{"index" => index, "ordinal" => ordinal, "message" => source}
    |> optional("eventReply", event_reply(raw, parts))
  end

  def pending_message(entry) do
    images = field(entry, :image_parts) || field(entry, :attachments) || []

    %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => field(entry, :content) || ""}
        | Enum.map(images, &pending_part/1)
      ]
    }
    |> optional("provenance", provenance(field(entry, :input_provenance)))
  end

  # PendingInputStore retains producer image structs, while durable transcript
  # parts already passed through Message.encode/1. Preserve the same real fields.
  defp pending_part(%Synapsis.Part.Image{media_type: media_type, data: data, path: path}) do
    part(%{type: "image", media_type: media_type, data: data, path: path})
  end

  defp pending_part(raw), do: part(raw)

  defp tool_envelope(message, "toolResult", [%{"type" => "toolResult"} = result]) do
    result
    |> Map.delete("type")
    |> Map.merge(message)
    |> Map.put("content", result["content"])
  end

  defp tool_envelope(message, _, _), do: message

  defp part(raw) do
    case field(raw, :type) do
      "text" ->
        %{"type" => "text", "text" => field(raw, :text) || field(raw, :content) || ""}

      "reasoning" ->
        %{"type" => "thinking", "thinking" => field(raw, :content) || field(raw, :text) || ""}
        |> optional("thinkingSignature", field(raw, :signature))

      "tool_use" ->
        %{
          "type" => "toolCall",
          "id" => field(raw, :id),
          "name" => field(raw, :name),
          "arguments" => field(raw, :input) || %{}
        }

      "tool_result" ->
        tool_result(raw)

      "image" ->
        %{"type" => "image"}
        |> optional("mimeType", field(raw, :media_type))
        |> optional("data", field(raw, :data))
        |> optional("path", field(raw, :path))

      _ ->
        # Keep actual portable host facts. Unknown host part kinds do not
        # acquire a source display/media/provenance producer identity.
        json_keys(raw)
    end
  end

  defp tool_result(raw) do
    public =
      case field(raw, :projection) do
        projection when is_map(projection) ->
          case {field(projection, :version), field(projection, :result)} do
            {1, result} when is_map(result) -> json_keys(result)
            _ -> %{"content" => field(raw, :content) || ""}
          end

        _ ->
          %{"content" => field(raw, :content) || ""}
      end

    # `details` is retained only when it is a genuine public result field.
    # Other native fields remain themselves, not an invented details envelope.
    public
    |> Map.delete("is_error")
    |> Map.put("type", "toolResult")
    |> Map.put("toolCallId", field(raw, :tool_use_id))
    |> Map.put("isError", field(raw, :is_error) || false)
  end

  defp event_reply(raw, parts) do
    message = %Message{
      role: field(raw, :role),
      reply_presentation: field(raw, :reply_presentation),
      parts:
        Enum.map(parts, fn part ->
          if field(part, :type) == "text",
            do: %Text{content: field(part, :text) || field(part, :content) || ""},
            else: part
        end)
    }

    case EventReply.project(message) do
      nil ->
        nil

      projection ->
        %{
          "version" => projection.version,
          "policy" => projection.policy,
          "hidden" => projection.hidden,
          "textOverrides" =>
            Enum.map(projection.text_parts, &%{"blockIndex" => &1.index, "text" => &1.text})
        }
    end
  end

  defp provenance(raw) when is_map(raw) do
    case field(raw, :kind) do
      kind when kind in ["external_user", "inter_session", "internal_system"] ->
        # Host UUIDs retain their real host keys. They are not sourceSessionKey,
        # jobId or runId facts and cannot activate those source services.
        json_keys(raw)
        |> optional("sourceTool", field(raw, :source_tool))

      _ ->
        nil
    end
  end

  defp provenance(_), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_), do: nil
  defp normalize_role(:tool), do: "toolResult"
  defp normalize_role("tool"), do: "toolResult"
  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role), do: role
  defp put_meta_id(message, nil), do: message
  defp put_meta_id(message, id), do: put_in(message, ["__openclaw", "id"], id)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp json_keys(value) when is_list(value), do: Enum.map(value, &json_keys/1)
  defp json_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_keys(item)} end)

  defp json_keys(value), do: value
end
