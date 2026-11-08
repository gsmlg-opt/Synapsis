defmodule Synapsis.Filesystem.Arguments do
  @moduledoc """
  Pure edit argument preparation and lexical path repair from OpenClaw 488631c.

  Preparation preserves literal payloads and projects JSON string-keyed maps;
  it does not perform final schema validation, resolve targets or execute tools.
  Path repair is separate and does not expand references or inspect files.

  Native strings must be valid UTF-8. Escaped unpaired UTF-16 surrogates that
  JavaScript can represent remain an unqualified cross-runtime boundary:
  Jason returns a parse error, handled by the documented error/fallback path.
  This owner does not establish complete `JSON.parse` equivalence.
  """

  # Algorithms adapted from OpenClaw 488631c, MIT License:
  # src/agents/sessions/tools/edit.ts:67-115,
  # packages/ai/src/utils/json-parse.ts:5-94 (preserveValidControlEscapes: true),
  # src/agents/agent-tools.params.ts:21-27,96-116,
  # packages/normalization-core/src/record-coerce.ts:1-4.
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

  @parse_error "Could not parse edits as JSON. Provide a complete JSON array of replacements."
  @xml_suffix ~r/<\/arg_value>>+\z/
  @office_extension ~r/\.(doc|ppt|xls)(?:odex|codex|xodex|xcodex)\z/i
  @office_extensions %{"doc" => ".docx", "ppt" => ".pptx", "xls" => ".xlsx"}
  @hex_digits "0123456789abcdef"

  @doc "Repairs serialized edits, removes metadata and appends a missing legacy pair."
  def prepare_edit(input) when is_map(input) and not is_struct(input) do
    if valid_utf8?(input) do
      with {:ok, args} <- parse_serialized_edits(input) do
        prepared = Map.take(args, ["path", "edits"])

        prepared =
          case Map.fetch(prepared, "edits") do
            {:ok, edits} when is_list(edits) ->
              Map.put(prepared, "edits", Enum.map(edits, &project_edit/1))

            _ ->
              prepared
          end

        {:ok, append_legacy_pair(prepared, args)}
      end
    else
      {:error, :invalid_input}
    end
  end

  def prepare_edit(_input), do: {:error, :invalid_input}

  @doc "Repairs only the terminal malformed XML suffix and Office extension family."
  def normalize_path(path) when is_binary(path) do
    if String.valid?(path) do
      repaired = String.replace(path, @xml_suffix, "")

      {:ok,
       Regex.replace(@office_extension, repaired, fn _match, family ->
         Map.fetch!(@office_extensions, String.downcase(family))
       end)}
    else
      {:error, :invalid_input}
    end
  end

  def normalize_path(_path), do: {:error, :invalid_input}

  defp parse_serialized_edits(%{"edits" => edits} = args) when is_binary(edits) do
    case Jason.decode(repair_json(edits)) do
      {:ok, parsed} when is_list(parsed) ->
        {:ok, Map.put(args, "edits", parsed)}

      {:ok, _non_array} ->
        {:ok, args}

      {:error, _reason} ->
        if complete_legacy_pair?(args),
          do: {:ok, args},
          else: {:error, {:tool_input_error, @parse_error}}
    end
  end

  defp parse_serialized_edits(args), do: {:ok, args}

  defp project_edit(edit) when is_map(edit) and not is_struct(edit),
    do: Map.take(edit, ["oldText", "newText"])

  defp project_edit(edit), do: edit

  defp append_legacy_pair(prepared, args) do
    if complete_legacy_pair?(args) do
      batch = if is_list(prepared["edits"]), do: prepared["edits"], else: []
      pair = Map.take(args, ["oldText", "newText"])

      present? =
        Enum.any?(batch, fn edit ->
          is_map(edit) and not is_struct(edit) and
            edit["oldText"] === pair["oldText"] and edit["newText"] === pair["newText"]
        end)

      Map.put(prepared, "edits", if(present?, do: batch, else: batch ++ [pair]))
    else
      prepared
    end
  end

  defp complete_legacy_pair?(args),
    do: is_binary(args["oldText"]) and is_binary(args["newText"])

  defp valid_utf8?(value) when is_binary(value), do: String.valid?(value)

  defp valid_utf8?(value) when is_map(value),
    do:
      Enum.all?(Map.to_list(value), fn {key, entry} -> valid_utf8?(key) and valid_utf8?(entry) end)

  defp valid_utf8?(value) when is_list(value), do: Enum.all?(value, &valid_utf8?/1)
  defp valid_utf8?(_value), do: true

  # This is only repairJson's authoritative-text mode. The Windows-prefix
  # heuristic is deliberately absent because valid control escapes must survive.
  defp repair_json(json) do
    json |> repair_json(false, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp repair_json(<<>>, _in_string, acc), do: acc

  defp repair_json(<<?", rest::binary>>, in_string, acc),
    do: repair_json(rest, not in_string, [<<?">> | acc])

  defp repair_json(<<?\\, ?u, a, b, c, d, rest::binary>>, true, acc)
       when (a in ?0..?9 or a in ?a..?f or a in ?A..?F) and
              (b in ?0..?9 or b in ?a..?f or b in ?A..?F) and
              (c in ?0..?9 or c in ?a..?f or c in ?A..?F) and
              (d in ?0..?9 or d in ?a..?f or d in ?A..?F),
       do: repair_json(rest, true, [<<?\\, ?u, a, b, c, d>> | acc])

  defp repair_json(<<?\\, next, rest::binary>>, true, acc)
       when next in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t],
       do: repair_json(rest, true, [<<?\\, next>> | acc])

  defp repair_json(<<?\\, rest::binary>>, true, acc),
    do: repair_json(rest, true, ["\\\\" | acc])

  defp repair_json(<<char, rest::binary>>, true, acc) when char <= 0x1F,
    do: repair_json(rest, true, [escape_control(char) | acc])

  defp repair_json(<<char, rest::binary>>, in_string, acc),
    do: repair_json(rest, in_string, [<<char>> | acc])

  defp escape_control(8), do: "\\b"
  defp escape_control(9), do: "\\t"
  defp escape_control(10), do: "\\n"
  defp escape_control(12), do: "\\f"
  defp escape_control(13), do: "\\r"

  defp escape_control(char),
    do:
      <<?\\, ?u, ?0, ?0, :binary.at(@hex_digits, div(char, 16)),
        :binary.at(@hex_digits, rem(char, 16))>>
end
