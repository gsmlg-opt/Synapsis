defmodule Synapsis.Filesystem.TextBudget do
  @moduledoc """
  Pure text budgets prepared from an explicit model context window.

  Mirrors OpenClaw 488631c's tool-result limits and complete CJK weight ranges.
  These are provider-independent estimates, not tokenizer counts. No model or
  application configuration is read here.
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

  @doc "Prepares the two source text allowances, or nil without a valid context."
  def resolve(context_tokens) when is_number(context_tokens) and context_tokens > 0 do
    tokens = floor(context_tokens)

    cap =
      cond do
        tokens >= 200_000 -> 64_000
        tokens >= 100_000 -> 32_000
        true -> 16_000
      end

    %{
      maxChars: min(floor(context_tokens * 0.3) * 4, cap),
      maxContextChars: max(1_024, max(1, tokens))
    }
  end

  def resolve(_), do: nil

  @doc "Checks both the producer estimate and the raw-weight context allowance."
  def fits?(_text, nil), do: true

  def fits?(text, %{maxChars: max_chars, maxContextChars: max_context_chars}) do
    chars = estimate(text)

    chars <= max_chars and
      (chars * 2 <= max_context_chars or estimate(text, 2) <= max_context_chars)
  end

  @doc "Estimates complete code points, preserving per-ASCII-run floor rounding."
  def estimate(text, minimum_raw_weight \\ 1) do
    estimate_points(text, max(1, minimum_raw_weight), 0, 0)
  end

  defp estimate_points(<<>>, weight, ascii, count), do: count + ceil(ascii * weight)

  defp estimate_points(<<point, rest::binary>>, weight, ascii, count) when point <= 0x7F,
    do: estimate_points(rest, weight, ascii + 1, count)

  defp estimate_points(<<point::utf8, rest::binary>>, weight, ascii, count) do
    units = if point > 0xFFFF, do: 2, else: 1
    cost = max(point_weight(point, units), ceil(units * weight))
    estimate_points(rest, weight, 0, count + ceil(ascii * weight) + cost)
  end

  # All five original categories, including the uncommon BMP and supplementary
  # ranges; broader Unicode CJK blocks would change the source estimator.
  for {ranges, cost} <- [
        {[
           {0x00B7, 0x00B7},
           {0x3000, 0x319F},
           {0x4E00, 0x9FA5},
           {0xAC00, 0xD7AF},
           {0xFF01, 0xFF60}
         ], 4},
        {[
           {0x1100, 0x11FF},
           {0x2E80, 0x2FFF},
           {0x31A0, 0x4DFF},
           {0x9FA6, 0x9FFF},
           {0xA000, 0xA4FF},
           {0xA700, 0xA707},
           {0xA960, 0xA97F},
           {0xD7B0, 0xD7FF},
           {0xF900, 0xFAFF}
         ], 12},
        {[
           {0x02C7, 0x02C7},
           {0x02C9, 0x02CB},
           {0x02D9, 0x02D9},
           {0x02EA, 0x02EB},
           {0x0305, 0x0305},
           {0x0323, 0x0323},
           {0xFE10, 0xFE4F},
           {0xFF61, 0xFFDC},
           {0xFFE0, 0xFFE6}
         ], 8},
        {[{0x1D360, 0x1D371}], 12},
        {[
           {0x16FE0, 0x16FFF},
           {0x1AFF0, 0x1AFFF},
           {0x1B000, 0x1B16F},
           {0x1F200, 0x1F2FF},
           {0x20000, 0x2FA1F},
           {0x30000, 0x3347F}
         ], 16}
      ],
      {first, last} <- ranges do
    defp point_weight(point, _units) when point >= unquote(first) and point <= unquote(last),
      do: unquote(cost)
  end

  defp point_weight(_point, units), do: units

  @doc "Fits a UTF-16-safe prefix to an explicit weighted character allowance."
  def slice(text, max_chars, minimum_raw_weight \\ 1) do
    budget = max(0, floor(max_chars))
    units = utf16_length(text)

    if units <= budget and estimate(text, minimum_raw_weight) <= budget do
      text
    else
      slice_search(text, budget, minimum_raw_weight, 0, min(units, budget), "")
    end
  end

  defp slice_search(_text, _budget, _weight, low, high, best) when low > high, do: best

  defp slice_search(text, budget, weight, low, high, best) do
    midpoint = div(low + high, 2)
    candidate = utf16_prefix(text, midpoint)

    if estimate(candidate, weight) <= budget,
      do: slice_search(text, budget, weight, midpoint + 1, high, candidate),
      else: slice_search(text, budget, weight, low, midpoint - 1, best)
  end

  @doc false
  def utf16_length(text), do: units(text, 0)

  defp units(<<>>, count), do: count

  defp units(<<point::utf8, rest::binary>>, count),
    do: units(rest, count + if(point > 0xFFFF, do: 2, else: 1))

  @doc false
  def utf16_prefix(text, units) do
    {bytes, _exact} = unit_offset(text, max(0, units), 0)
    binary_part(text, 0, bytes)
  end

  @doc false
  def utf16_offset(text, units), do: unit_offset(text, units, 0)

  defp unit_offset(_text, 0, bytes), do: {bytes, true}
  defp unit_offset(<<>>, _units, bytes), do: {bytes, false}

  defp unit_offset(<<point::utf8, rest::binary>> = text, units, bytes) do
    width = if point > 0xFFFF, do: 2, else: 1

    if units < width,
      do: {bytes, false},
      else: unit_offset(rest, units - width, bytes + byte_size(text) - byte_size(rest))
  end
end
