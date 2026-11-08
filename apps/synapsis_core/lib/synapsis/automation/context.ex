defmodule Synapsis.Automation.Context do
  @moduledoc """
  Pure role-and-text projection for a current-bound automation's source session.

  The ordinary text format and UTF-16 limits follow OpenClaw 488631c's
  `cron/isolated-agent/run-current-context.ts`. This accepts Synapsis host parts
  and native runtime messages; it does not implement OpenClaw's transcript
  envelopes, forwarded-message or other Gateway display conventions.

  Only the newest 220 input messages are projected. Their visible text has a
  256-KiB UTF-8 budget, retaining a suffix ending at the newest message. This is
  an in-memory projection bound, not a storage read or pre-decode memory bound;
  callers must separately bound durable reads. No session or provider I/O occurs.
  """

  alias Synapsis.Part.Text

  @raw_messages 220
  @input_bytes 256 * 1024
  @messages 10
  @line_units 220
  @block_units 1_400
  @header "Recent conversation:"
  # ECMAScript whitespace also includes the byte-order mark and these Unicode
  # spaces; normalize before adding the role prefix, as the reference does.
  @whitespace ~r/[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+/u

  @spec format([map()]) :: String.t() | nil
  def format(messages) when is_list(messages) do
    messages
    |> bounded_text_messages()
    |> Enum.flat_map(fn {role, texts} ->
      text = texts |> Enum.map(&display_text/1) |> Enum.join(" ") |> normalize()
      if text == "", do: [], else: [format_line(role, text)]
    end)
    |> Enum.take(-@messages)
    |> fit_block()
  end

  defp bounded_text_messages(messages) do
    messages
    |> Enum.take(-@raw_messages)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn message, {kept, used} ->
      case role_text(message) do
        nil ->
          {:cont, {kept, used}}

        {role, texts} ->
          bytes = Enum.reduce(texts, 0, &(byte_size(&1) + &2))

          if used + bytes <= @input_bytes,
            do: {:cont, {[{role, texts} | kept], used + bytes}},
            else: {:halt, {kept, used}}
      end
    end)
    |> elem(0)
  end

  defp role_text(message) when is_map(message) do
    role = field(message, :role)

    if role in [:user, :assistant, "user", "assistant"] do
      content = field(message, :parts) || field(message, :content) || field(message, :text)
      {role, text_parts(content)}
    end
  end

  defp role_text(_), do: nil

  defp text_parts(text) when is_binary(text), do: [text]

  defp text_parts(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      %Text{content: text} when is_binary(text) ->
        [text]

      part when is_map(part) ->
        text = field(part, :text)
        if field(part, :type) in [:text, "text"] and is_binary(text), do: [text], else: []

      _ ->
        []
    end)
  end

  defp text_parts(_), do: []

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # The reference display projection caps each ordinary text block before its
  # whitespace normalization and the final role-aware line truncation.
  defp display_text(text) do
    case take_utf16(text, @line_units) do
      {prefix, false} -> prefix
      {prefix, true} -> prefix <> "\n...(truncated)..."
    end
  end

  defp normalize(text), do: text |> String.replace(@whitespace, " ") |> String.trim(" ")

  defp format_line(role, text) do
    prefix = if role in [:user, "user"], do: "- User: ", else: "- Assistant: "
    limit = @line_units - byte_size(prefix)

    case take_utf16(text, limit) do
      {body, false} ->
        prefix <> body

      {_body, true} ->
        {body, _} = take_utf16(text, limit - 3)
        prefix <> String.trim_trailing(body, " ") <> "..."
    end
  end

  defp fit_block([]), do: nil

  defp fit_block(lines) do
    block = Enum.join([@header | lines], "\n")

    case take_utf16(block, @block_units) do
      {_, false} -> block
      {_, true} -> fit_block(tl(lines))
    end
  end

  # Counting code points rather than graphemes matches JS string widths while
  # leaving supplementary code points (UTF-16 surrogate pairs) intact.
  defp take_utf16(text, limit), do: take_utf16(text, text, limit, 0)

  defp take_utf16(original, "", _remaining, bytes),
    do: {binary_part(original, 0, bytes), false}

  defp take_utf16(original, <<point::utf8, tail::binary>> = rest, remaining, bytes) do
    units = if point > 0xFFFF, do: 2, else: 1

    if units <= remaining,
      do:
        take_utf16(original, tail, remaining - units, bytes + byte_size(rest) - byte_size(tail)),
      else: {binary_part(original, 0, bytes), true}
  end
end
