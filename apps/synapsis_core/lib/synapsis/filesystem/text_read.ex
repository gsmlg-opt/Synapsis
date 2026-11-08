defmodule Synapsis.Filesystem.TextRead do
  @moduledoc """
  Pages an immutable, valid UTF-8 text snapshot using OpenClaw 488631c semantics.

  Offsets are one-based lines; cursors count UTF-16 units within the first
  selected line. This text-only API does not classify attachments, decode Windows
  files, resolve paths or execute tools. `Local.read_text/4` owns guarded I/O.
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

  @max_lines 2_000
  @max_bytes 51_200
  @safe_integer 9_007_199_254_740_991

  @doc "Returns detached display text and raw text/continuation details."
  def page(snapshot, args, opts \\ []) do
    with :ok <- validate(snapshot, args, opts) do
      text = snapshot |> remove_bom() |> String.replace("\r\n", "\n")
      offset = Map.get(args, "offset", 1)
      cursor = Map.get(args, "cursor", 0)
      limit = if Map.has_key?(args, "limit"), do: max(1, floor(args["limit"]))
      selection = select(text, offset - 1, limit)
      prefix = Keyword.get(opts, :prefix, "")

      source_bytes = Keyword.get(opts, :source_bytes, byte_size(snapshot))
      render_selection(text, source_bytes, selection, offset, cursor, limit, prefix, opts)
    end
  end

  defp validate(snapshot, args, opts) do
    if is_binary(snapshot) and String.valid?(snapshot) and is_map(args) and
         not is_struct(args) and Map.keys(args) -- ["offset", "cursor", "limit"] == [] and
         Enum.all?(args, &valid_arg?/1) and Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:prefix, :max_bytes, :model_budget, :source_bytes] == [] and
         Enum.all?(opts, &valid_option?/1),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp valid_arg?({"offset", n}), do: is_integer(n) and n >= 1 and n <= @safe_integer
  defp valid_arg?({"cursor", n}), do: is_integer(n) and n >= 0 and n <= @safe_integer
  defp valid_arg?({"limit", n}), do: is_number(n)

  defp valid_option?({:prefix, prefix}), do: is_binary(prefix) and String.valid?(prefix)

  defp valid_option?({:source_bytes, n}), do: is_integer(n) and n >= 0

  defp valid_option?({:max_bytes, n}),
    do: is_integer(n) and n > 0 and n <= @safe_integer

  defp valid_option?({:model_budget, nil}), do: true

  defp valid_option?({:model_budget, %{maxChars: chars, maxContextChars: context} = budget}),
    do:
      map_size(budget) == 2 and is_number(chars) and is_number(context) and chars >= 0 and
        context >= 0

  defp valid_option?(_), do: false

  defp remove_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp remove_bom(text), do: text

  # Only byte positions and counts are retained, including for discarded lines.
  # A final LF terminates a line rather than creating another empty line.
  defp select(text, start_line, limit) do
    scan(text, 0, start_line, limit, %{
      total: 0,
      count: 0,
      start: 0,
      finish: 0,
      first_end: 0,
      has_text: false
    })
  end

  defp scan(text, position, _start_line, _limit, state) when position >= byte_size(text),
    do: state

  defp scan(text, position, start_line, limit, state) do
    finish = line_end(text, position)

    state =
      if state.total >= start_line and (is_nil(limit) or state.count < limit) do
        %{
          state
          | start: if(state.count == 0, do: position, else: state.start),
            first_end: if(state.count == 0, do: finish, else: state.first_end),
            finish: finish,
            count: state.count + 1,
            has_text: state.has_text or finish > position
        }
      else
        state
      end

    scan(text, finish + 1, start_line, limit, %{state | total: state.total + 1})
  end

  defp line_end(text, start) do
    case :binary.match(text, "\n", scope: {start, byte_size(text) - start}) do
      :nomatch -> byte_size(text)
      {position, 1} -> position
    end
  end

  defp render_selection(text, source_bytes, selected, offset, cursor, limit, prefix, opts) do
    first_line = binary_part(text, selected.start, selected.first_end - selected.start)
    first_length = TextBudget.utf16_length(first_line)

    cond do
      selected.total == 0 ->
        message =
          if source_bytes == 0,
            do: "File is empty (0 bytes).",
            else: "File contains no readable text (#{source_bytes} bytes)."

        message_result(prefix <> message)

      offset > selected.total ->
        message_result(
          prefix <>
            "Offset #{offset} is beyond end of file (#{selected.total} lines total). Retry with offset <= #{selected.total}."
        )

      cursor > 0 and cursor >= first_length ->
        next = if offset < selected.total, do: " Use offset=#{offset + 1} to continue.", else: ""

        message_result(
          prefix <>
            "Cursor #{cursor} is at or beyond the end of line #{offset} (#{first_length} characters).#{next}"
        )

      true ->
        case TextBudget.utf16_offset(first_line, cursor) do
          {_bytes, false} ->
            {:error, :invalid_cursor}

          {bytes, true} ->
            end_line = offset - 1 + selected.count
            finish = if end_line == selected.total, do: byte_size(text), else: selected.finish
            start = selected.start + bytes
            content = binary_part(text, start, finish - start)
            call_max = Keyword.get(opts, :max_bytes, @max_bytes)

            params = %{
              content: content,
              start_line: offset,
              end_line: end_line,
              total_lines: selected.total,
              cursor: cursor,
              limit: if(is_nil(limit), do: nil, else: selected.count),
              max_bytes: call_max,
              page_max: min(@max_bytes, call_max) - byte_size(prefix),
              model_budget: Keyword.get(opts, :model_budget),
              prefix: prefix,
              adaptive: Keyword.has_key?(opts, :max_bytes)
            }

            {display, details} = bounded_page(params)

            display =
              if selected.has_text do
                display
              else
                subject =
                  if offset == 1 and end_line == selected.total,
                    do: "File",
                    else: "Selected range"

                plural = if selected.count == 1, do: "", else: "s"

                notice =
                  binary_part(
                    display,
                    byte_size(details.content),
                    byte_size(display) - byte_size(details.content)
                  )

                "#{subject} contains #{selected.count} blank line#{plural}." <> notice
              end

            {:ok,
             %{
               content: [%{type: "text", text: :binary.copy(prefix <> display)}],
               details: %{details | content: :binary.copy(details.content)}
             }}
        end
    end
  end

  defp message_result(text),
    do: {:ok, %{content: [%{type: "text", text: text}], details: %{kind: "text", content: text}}}

  defp bounded_page(params) do
    remaining = params.total_lines - params.end_line

    notice =
      if not is_nil(params.limit) and remaining > 0 do
        plural = if remaining == 1, do: "", else: "s"

        "\n\n[#{remaining} more line#{plural} in file. Use offset=#{params.end_line + 1} to continue.]"
      else
        ""
      end

    if params.end_line - params.start_line < @max_lines and
         byte_size(params.content) + byte_size(notice) <= params.page_max and
         TextBudget.fits?(params.prefix <> params.content <> notice, params.model_budget) do
      complete_page(params.content, notice, params)
    else
      cap_page(params, notice)
    end
  end

  defp complete_page(content, "", _params), do: {content, %{kind: "text", content: content}}

  defp complete_page(content, notice, params) do
    continuation = with_limit(%{kind: "line", offset: params.end_line + 1}, params.limit)

    {content <> notice,
     %{
       kind: "truncated",
       content: content,
       continuation: continuation,
       truncation: %{
         truncated: true,
         truncatedBy: "lines",
         totalLines: params.total_lines,
         totalBytes: byte_size(params.content),
         outputLines: params.end_line - params.start_line + 1,
         outputBytes: byte_size(content),
         lastLinePartial: false,
         firstLineExceedsLimit: false,
         maxLines: params.limit || @max_lines,
         maxBytes: params.page_max
       }
     }}
  end

  defp cap_page(params, limit_notice) do
    first_line = binary_part(params.content, 0, line_end(params.content, 0))

    cursor_estimate =
      with_limit(
        %{
          kind: "cursor",
          offset: params.start_line,
          cursor: params.cursor + TextBudget.utf16_length(first_line)
        },
        params.limit
      )

    line_estimate = with_limit(%{kind: "line", offset: params.total_lines + 1}, params.limit)

    reserved =
      max(
        byte_size(continuation_notice(cursor_estimate, params)),
        byte_size(continuation_notice(line_estimate, params))
      )

    prefix = utf8_prefix(params.content, max(0, params.page_max - reserved))

    prefix =
      case params.model_budget do
        nil ->
          prefix

        budget ->
          prefix
          |> TextBudget.slice(budget.maxChars - reserved - TextBudget.estimate(params.prefix))
          |> TextBudget.slice(
            budget.maxContextChars - reserved * 2 - TextBudget.estimate(params.prefix, 2),
            2
          )
      end

    truncation = truncate_head(params.content, byte_size(prefix))

    if truncation.truncated do
      {content, continuation} =
        if truncation.firstLineExceedsLimit do
          content = utf8_prefix(first_line, byte_size(prefix))

          {content,
           with_limit(
             %{
               kind: "cursor",
               offset: params.start_line,
               cursor: params.cursor + TextBudget.utf16_length(content)
             },
             params.limit
           )}
        else
          next_offset = params.start_line + truncation.outputLines
          limit = if params.limit, do: max(1, params.end_line - next_offset + 1)
          {truncation.content, with_limit(%{kind: "line", offset: next_offset}, limit)}
        end

      metadata =
        truncation
        |> Map.delete(:content)
        |> Map.merge(%{
          totalLines: params.total_lines,
          outputBytes: byte_size(content),
          firstLineExceedsLimit: false,
          lastLinePartial: continuation.kind == "cursor"
        })

      {content <> continuation_notice(continuation, params),
       %{kind: "truncated", content: content, continuation: continuation, truncation: metadata}}
    else
      complete_page(truncation.content, limit_notice, params)
    end
  end

  defp with_limit(continuation, nil), do: continuation
  defp with_limit(continuation, limit), do: Map.put(continuation, :limit, limit)

  defp continuation_notice(continuation, params) do
    cursor = if continuation.kind == "cursor", do: ", cursor=#{continuation.cursor}", else: ""
    limit = if Map.has_key?(continuation, :limit), do: ", limit=#{continuation.limit}", else: ""

    if params.adaptive do
      budget = params.max_bytes |> format_size() |> String.replace(".0KB", "KB")

      "\n\n[Read output capped at #{budget} for this call. Use offset=#{continuation.offset}#{cursor}#{limit} to continue.]"
    else
      {label, action} =
        if continuation.kind == "cursor",
          do: {"part of line #{params.start_line}", "Use read with"},
          else:
            {"lines #{params.start_line}-#{continuation.offset - 1} of #{params.total_lines}",
             "Use"}

      "\n\n[Showing #{label} (#{format_size(params.max_bytes)} limit). #{action} offset=#{continuation.offset}#{cursor}#{limit} to continue.]"
    end
  end

  defp format_size(bytes) when bytes < 1_024, do: "#{bytes}B"

  defp format_size(bytes) when bytes < 1_024 * 1_024,
    do: :erlang.float_to_binary(bytes / 1_024, decimals: 1) <> "KB"

  defp format_size(bytes),
    do: :erlang.float_to_binary(bytes / (1_024 * 1_024), decimals: 1) <> "MB"

  defp utf8_prefix(text, bytes) do
    finish = utf8_boundary(text, min(byte_size(text), max(0, bytes)))
    binary_part(text, 0, finish)
  end

  defp utf8_boundary(text, position) when position == byte_size(text) or position == 0,
    do: position

  defp utf8_boundary(text, position) do
    if :binary.at(text, position) in 0x80..0xBF,
      do: utf8_boundary(text, position - 1),
      else: position
  end

  defp truncate_head(content, max_bytes) do
    total_lines = select(content, 0, 0).total

    base = %{
      content: content,
      truncated: false,
      truncatedBy: nil,
      totalLines: total_lines,
      totalBytes: byte_size(content),
      outputLines: total_lines,
      outputBytes: byte_size(content),
      lastLinePartial: false,
      firstLineExceedsLimit: false,
      maxLines: @max_lines,
      maxBytes: max_bytes
    }

    cond do
      total_lines <= @max_lines and byte_size(content) <= max_bytes ->
        base

      total_lines > 0 and line_end(content, 0) > max_bytes ->
        %{
          base
          | content: "",
            truncated: true,
            truncatedBy: "bytes",
            outputLines: 0,
            outputBytes: 0,
            firstLineExceedsLimit: true
        }

      true ->
        {finish, count, bytes, cause} = head_lines(content, 0, 0, 0, total_lines, max_bytes)

        %{
          base
          | content: binary_part(content, 0, finish),
            truncated: true,
            truncatedBy: cause,
            outputLines: count,
            outputBytes: bytes
        }
    end
  end

  defp head_lines(_content, _start, count, finish, total, _max_bytes)
       when count >= @max_lines or count >= total do
    cause = if total > @max_lines and count >= @max_lines, do: "lines", else: "bytes"
    {finish, count, finish, cause}
  end

  defp head_lines(content, start, count, finish, total, max_bytes) do
    next_finish = line_end(content, start)

    if next_finish > max_bytes,
      do: {finish, count, finish, "bytes"},
      else: head_lines(content, next_finish + 1, count + 1, next_finish, total, max_bytes)
  end
end
