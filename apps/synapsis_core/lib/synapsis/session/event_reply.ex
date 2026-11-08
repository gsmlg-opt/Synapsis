defmodule Synapsis.Session.EventReply do
  @moduledoc """
  Pure display projection for newly admitted manual-event assistant replies.

  Raw Message text remains authoritative for persistence and model replay. The
  versioned stamp opts only presentation consumers into the pinned OpenClaw
  message-mode HEARTBEAT_OK policy; it does not infer provenance from history.
  """

  alias Synapsis.{Message, Part.Text}

  @token "HEARTBEAT_OK"
  @policy "manual_event_message"

  # ECMAScript WhiteSpace + LineTerminator, deliberately excluding NEL/MVS.
  @space "\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @leading_space Regex.compile!("^[" <> @space <> "]+", "u")
  @trailing_space Regex.compile!("[" <> @space <> "]+$", "u")
  @spaces Regex.compile!("[" <> @space <> "]+", "u")

  @doc "Host-owned provenance stamp; contains no normalized text."
  def stamp(occurrence_id) when is_binary(occurrence_id) do
    %{"version" => 1, "policy" => @policy, "occurrence_id" => occurrence_id}
  end

  @doc "Exact pinned stripHeartbeatToken helper behavior in message mode."
  def strip_heartbeat_token(raw) when is_binary(raw) do
    trimmed = trim(raw)

    cond do
      trimmed == "" ->
        %{text: "", did_strip: false, should_skip: true}

      not String.contains?(trimmed, @token) ->
        %{text: trimmed, did_strip: false, should_skip: false}

      true ->
        original = strip_edges(trimmed)
        normalized = trimmed |> strip_markup() |> strip_edges()

        {rest, stripped?} =
          case original do
            {text, true} when text != "" -> original
            _ -> normalized
          end

        if stripped? do
          rest = trim(rest)
          %{text: rest, did_strip: true, should_skip: rest == ""}
        else
          %{text: trimmed, did_strip: false, should_skip: false}
        end
    end
  end

  @doc "Display callsite: token-free authored formatting is byte-preserving."
  def text(raw) when is_binary(raw) do
    if String.contains?(raw, @token), do: strip_heartbeat_token(raw).text, else: raw
  end

  @doc "Additive text overrides for a tagged assistant; nil leaves raw rendering."
  def project(%Message{role: role, reply_presentation: stamp} = message)
      when role in ["assistant", :assistant] and is_map(stamp) do
    with 1 <- fetch(stamp, :version),
         @policy <- fetch(stamp, :policy),
         occurrence_id when is_binary(occurrence_id) <- fetch(stamp, :occurrence_id) do
      parts = message.parts || []

      text_parts =
        parts
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%Text{content: content}, index} -> [%{index: index, text: text(content || "")}]
          {_part, _index} -> []
        end)

      projected_text =
        text_parts
        |> Enum.map(& &1.text)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      %{
        version: 1,
        policy: @policy,
        occurrence_id: occurrence_id,
        hidden: projected_text == "" and Enum.all?(parts, &match?(%Text{}, &1)),
        text: projected_text,
        text_parts: text_parts
      }
    else
      _ -> nil
    end
  end

  def project(%Message{}), do: nil

  @doc "A display-only Message copy, or nil for a contentless tagged assistant."
  def display_message(%Message{} = message) do
    case project(message) do
      nil ->
        message

      %{hidden: true} ->
        nil

      %{text_parts: overrides} ->
        replacements = Map.new(overrides, &{&1.index, &1.text})

        parts =
          message.parts
          |> Enum.with_index()
          |> Enum.map(fn
            {%Text{} = part, index} -> %{part | content: Map.fetch!(replacements, index)}
            {part, _index} -> part
          end)

        %{message | parts: parts}
    end
  end

  defp strip_edges(raw) do
    trimmed = trim(raw)

    if trimmed == "" or not String.contains?(trimmed, @token) do
      {trimmed, false}
    else
      {text, stripped?} = strip_edges_loop(trimmed, false)
      {text |> String.replace(@spaces, " ") |> trim(), stripped?}
    end
  end

  defp strip_edges_loop(text, stripped?) do
    next = trim(text)

    if String.starts_with?(next, @token) do
      rest = binary_part(next, byte_size(@token), byte_size(next) - byte_size(@token))
      strip_edges_loop(trim_start(rest), true)
    else
      case trailing_token(next) do
        {:ok, before, after_token} ->
          rest = trim_end(before) <> trim_start(after_token)
          strip_edges_loop(trim_end(rest), true)

        :none ->
          {text, stripped?}
      end
    end
  end

  # JavaScript's original regex has no Unicode flag: \w is ASCII and astral
  # characters consume two of its maximum four trailing UTF-16 code units.
  defp trailing_token(text) do
    case List.last(:binary.matches(text, @token)) do
      {index, length} ->
        after_token = binary_part(text, index + length, byte_size(text) - index - length)

        if not Regex.match?(~r/[A-Za-z0-9_]/, after_token) and utf16_size(after_token) <= 4 do
          {:ok, binary_part(text, 0, index), after_token}
        else
          :none
        end

      nil ->
        :none
    end
  end

  defp utf16_size(text) do
    for <<codepoint::utf8 <- text>>, reduce: 0 do
      size -> size + if(codepoint > 0xFFFF, do: 2, else: 1)
    end
  end

  defp strip_markup(text) do
    text
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/&nbsp;/i, " ")
    |> String.replace(~r/^[*`~_]+/, "")
    |> String.replace(~r/[*`~_]+$/, "")
  end

  defp trim_start(text), do: String.replace(text, @leading_space, "")
  defp trim_end(text), do: String.replace(text, @trailing_space, "")
  defp trim(text), do: text |> trim_start() |> trim_end()
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
