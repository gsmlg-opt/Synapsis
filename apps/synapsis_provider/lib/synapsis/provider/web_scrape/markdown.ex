defmodule Synapsis.Provider.WebScrape.Markdown do
  @moduledoc false

  # Ordinary Markdown conversion follows the pinned web-fetch-utils helper. Code
  # placeholders keep prose formatting from changing literal fenced contents.
  @space "\\x{0009}-\\x{000D} \\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @line_start "(?:\\A|(?<=[\\r\\n\\x{2028}\\x{2029}]))"
  @heading Regex.compile!(@line_start <> "\#{1,6}[" <> @space <> "]+", "u")
  @unordered Regex.compile!(
               @line_start <>
                 "[" <>
                 String.replace(@space, "\\x{0009}-\\x{000D}", "\\x{0009}\\x{000B}-\\x{000D}") <>
                 "]*[-*+][" <> @space <> "]+",
               "u"
             )
  @ordered Regex.compile!(
             @line_start <>
               "[" <>
               String.replace(@space, "\\x{0009}-\\x{000D}", "\\x{0009}\\x{000B}-\\x{000D}") <>
               "]*[0-9]+\\.[" <> @space <> "]+",
             "u"
           )
  @trim Regex.compile!("\\A[" <> @space <> "]+|[" <> @space <> "]+\\z", "u")

  def to_text(markdown) do
    {text, blocks} = protect(markdown, 0, "", [])

    text
    |> replace(~r/!\[[^\]]*\]\([^)]+\)/u, "")
    |> replace(~r/\[([^\]]+)\]\([^)]+\)/u, "\\1")
    |> replace(~r/`([^`]+)`/u, "\\1")
    |> replace(@heading, "")
    |> replace(@unordered, "")
    |> replace(@ordered, "")
    |> replace(~r/\r/u, "")
    |> replace(~r/[ \t]+\n/u, "\n")
    |> replace(~r/\n{3,}/u, "\n\n")
    |> replace(~r/[ \t]{2,}/u, " ")
    |> replace(@trim, "")
    |> restore(blocks)
  end

  defp protect(markdown, pos, text, blocks) do
    case find(markdown, "```", pos) do
      nil ->
        {text <> escape(slice(markdown, pos, byte_size(markdown))), blocks}

      open ->
        text = text <> escape(slice(markdown, pos, open))
        after_open = run_end(markdown, open)
        close = closing(markdown, after_open, after_open - open)
        first_line_end = find(markdown, "\n", after_open)
        line_start = markdown |> binary_part(0, open) |> :binary.matches("\n") |> List.last()
        line_start = if line_start, do: elem(line_start, 0) + 1, else: 0

        if is_nil(close) and
             (is_nil(first_line_end) or
                not Regex.match?(~r/\A[ \t]*\z/, slice(markdown, line_start, open))) do
          {text <> escape(slice(markdown, open, byte_size(markdown))), blocks}
        else
          content_end = if close, do: elem(close, 0), else: byte_size(markdown)

          content_start =
            if is_nil(first_line_end) or first_line_end > content_end,
              do: after_open,
              else: first_line_end + 1

          code = slice(markdown, content_start, content_end)

          line_end =
            case Regex.run(~r/[\r\n\x{2028}\x{2029}]\z/u, code) do
              [ending] -> ending
              _ -> ""
            end

          literal = binary_part(code, 0, byte_size(code) - byte_size(line_end))

          {text, blocks} =
            if literal == "",
              do: {text, blocks},
              else:
                {text <> <<0>> <> Integer.to_string(length(blocks)) <> <<0>>, blocks ++ [literal]}

          next = if close, do: elem(close, 1), else: byte_size(markdown)
          protect(markdown, next, text <> line_end, blocks)
        end
    end
  end

  defp closing(markdown, pos, width) do
    case find(markdown, "`", pos) do
      nil ->
        nil

      start ->
        finish = run_end(markdown, start)

        if finish - start >= width,
          do: {start, start + width},
          else: closing(markdown, finish, width)
    end
  end

  defp run_end(markdown, pos) when pos >= byte_size(markdown), do: pos

  defp run_end(markdown, pos) do
    if :binary.at(markdown, pos) == ?`, do: run_end(markdown, pos + 1), else: pos
  end

  defp find(value, needle, pos) do
    case :binary.match(value, needle, scope: {pos, byte_size(value) - pos}) do
      {start, _} -> start
      :nomatch -> nil
    end
  end

  defp restore(text, blocks) do
    blocks = List.to_tuple(blocks)

    Regex.replace(~r/\x00(?:\x00|(\d+)\x00)/u, text, fn
      _, "" -> <<0>>
      _, index -> elem(blocks, String.to_integer(index))
    end)
  end

  defp replace(value, regex, replacement), do: Regex.replace(regex, value, replacement)
  defp escape(text), do: String.replace(text, <<0>>, <<0, 0>>)
  defp slice(value, start, finish), do: binary_part(value, start, finish - start)
end
