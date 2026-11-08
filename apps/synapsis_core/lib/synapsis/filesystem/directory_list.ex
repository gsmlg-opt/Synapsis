defmodule Synapsis.Filesystem.DirectoryList do
  @moduledoc """
  Pure direct-directory pages using OpenClaw 488631c ls semantics.

  Names and cursors compare as UTF-16 code units. Only complete JSON-quoted
  names and continuation footers are returned; Local owns physical capture.
  """

  # Algorithms adapted from OpenClaw 488631c, MIT License.
  # Copyright (c) 2026 OpenClaw Foundation
  #
  # Permission is hereby granted, free of charge, to any person obtaining a copy
  # of this software and associated documentation files (the "Software"), to deal
  # in the Software without restriction, including without limitation the rights
  # to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  # copies of the Software, and to permit persons to whom the Software is
  # furnished to do so, subject to the following conditions:
  #
  # The above copyright notice and this permission notice shall be included in all
  # copies or substantial portions of the Software.
  #
  # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  # IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  # FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  # AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  # LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  # OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  # SOFTWARE.

  alias Synapsis.Filesystem.TextBudget

  @max_bytes 51_200
  @default_limit 500

  @doc "Renders a detached name snapshot and raw filename continuation."
  def page(entries, args, opts \\ []) do
    with :ok <- validate(args, opts),
         true <- is_list(entries) and Enum.all?(entries, &valid_entry?/1) do
      after_key = if Map.has_key?(args, "after"), do: utf16_key(args["after"])

      entries =
        entries
        |> Enum.map(&{utf16_key(&1.name), &1})
        |> Enum.filter(fn {key, _entry} -> is_nil(after_key) or key > after_key end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      case entries do
        [] -> result("(empty directory)")
        _ -> render(entries, max(1, floor(Map.get(args, "limit", @default_limit))), opts)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc false
  def validate(args, opts \\ []) do
    if is_map(args) and not is_struct(args) and Map.keys(args) -- ["after", "limit"] == [] and
         Enum.all?(args, &valid_arg?/1) and Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:model_budget] == [] and Enum.all?(opts, &valid_option?/1),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp valid_arg?({"after", name}), do: valid_name?(name)
  defp valid_arg?({"limit", limit}), do: is_number(limit)

  defp valid_option?({:model_budget, nil}), do: true

  defp valid_option?({:model_budget, %{maxChars: chars, maxContextChars: context} = budget}),
    do:
      not is_struct(budget) and map_size(budget) == 2 and is_number(chars) and
        is_number(context) and chars >= 0 and context >= 0

  defp valid_option?(_), do: false

  defp valid_entry?(%{name: name, is_directory: directory} = entry),
    do:
      not is_struct(entry) and map_size(entry) == 2 and valid_name?(name) and
        is_boolean(directory)

  defp valid_entry?(_), do: false
  defp valid_name?(name), do: is_binary(name) and String.valid?(name)

  # Big-endian encoding keeps binary comparison identical to raw JS strings,
  # including supplementary scalars that sort before later BMP code units.
  defp utf16_key(name), do: :unicode.characters_to_binary(name, :utf8, {:utf16, :big})

  defp render(entries, limit, opts) do
    budget = Keyword.get(opts, :model_budget)

    {lines, _content, count} =
      Enum.reduce_while(entries, {[], "", 0}, fn entry, {lines, content, count} = state ->
        if count >= limit do
          {:halt, state}
        else
          line = quote_name(entry.name <> if(entry.is_directory, do: "/", else: ""))
          candidate = if count == 0, do: line, else: content <> "\n" <> line

          if fits?(candidate, budget),
            do: {:cont, {[{entry.name, line} | lines], candidate, count + 1}},
            else: {:halt, state}
        end
      end)

    finish(lines, count, length(entries), budget)
  end

  defp finish([], _count, _total, _budget), do: {:error, :output_limit}

  defp finish([{last_name, _line} | rest] = lines, count, total, budget) do
    content = lines |> Enum.reverse() |> Enum.map_join("\n", &elem(&1, 1))
    next_after = if count < total, do: last_name

    output =
      if is_nil(next_after),
        do: content,
        else:
          content <>
            "\n\n[More entries. Continue with the same path and after=#{quote_name(next_after)}.]"

    if fits?(output, budget),
      do: result(output, next_after),
      else: finish(rest, count - 1, total, budget)
  end

  # JSON.stringify spells control hex escapes with lowercase digits. Encode raw
  # valid UTF-8 once so literal backslashes and filename case cannot be rewritten.
  defp quote_name(name), do: IO.iodata_to_binary([?", quote_characters(name, []), ?"])

  defp quote_characters(<<>>, escaped), do: Enum.reverse(escaped)

  defp quote_characters(<<point::utf8, rest::binary>>, escaped),
    do: quote_characters(rest, [quote_character(point) | escaped])

  defp quote_character(8), do: "\\b"
  defp quote_character(9), do: "\\t"
  defp quote_character(10), do: "\\n"
  defp quote_character(12), do: "\\f"
  defp quote_character(13), do: "\\r"
  defp quote_character(?"), do: "\\\""
  defp quote_character(?\\), do: "\\\\"

  defp quote_character(point) when point < 0x20,
    do: ["\\u00", hex_digit(div(point, 16)), hex_digit(rem(point, 16))]

  defp quote_character(point), do: <<point::utf8>>

  defp hex_digit(digit) when digit < 10, do: ?0 + digit
  defp hex_digit(digit), do: ?a + digit - 10

  defp fits?(text, budget), do: byte_size(text) <= @max_bytes and TextBudget.fits?(text, budget)

  defp result(text, next_after \\ nil) do
    details =
      if is_nil(next_after), do: %{content: text}, else: %{content: text, nextAfter: next_after}

    {:ok, %{content: [%{type: "text", text: text}], details: details}}
  end
end
