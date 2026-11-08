defmodule Synapsis.Diffs.Request do
  @moduledoc """
  Pure, internal Diffs request preparation from OpenClaw 488631c.

  `prepare/2` returns `{:ok, plan}` (or the unchanged `content`/`details`
  result), with JSON string keys, and `{:error, :invalid_input}` for invalid
  input. Arguments follow the pinned tool schema: numeric values, exact camel
  case keys and valid UTF-8 strings. Raw callback numeric-string/snake-case
  coercion and JavaScript lone UTF-16 surrogates are outside this contract.

  The caller supplies every already-resolved `defaults` field, plus optional
  `context` and `languagePackAvailable`. Defaults are never read or selected
  here. A plan contains `input`, `options`, `renderTarget`, `mode`, `ttlMs`
  and optional `context`; absent JavaScript properties are omitted. This
  module does not register a tool, render, store, deliver or apply a diff.
  `path` is a display label. Preparation stops before `renderDiffDocument`;
  `baseUrl` is accepted but not consumed, since viewer URL resolution happens
  after rendering in the reference callback.
  """

  # Adapted from OpenClaw 488631c extensions/diffs/src/{tool,config,types}.ts.
  # MIT License, Copyright (c) 2026 OpenClaw Foundation
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

  @modes ~w(view image file both)
  @enums %{
    "mode" => @modes,
    "theme" => ~w(light dark),
    "layout" => ~w(unified split),
    "fileQuality" => ~w(standard hq print),
    "fileFormat" => ~w(png pdf)
  }
  @strings ~w(before after patch path lang title baseUrl)
  @numbers %{"fileScale" => {1, 4}, "fileMaxWidth" => {640, 2400}, "ttlSeconds" => {1, 21_600}}
  @default_strings ~w(fontFamily)
  @default_numbers ~w(fontSize lineSpacing fileScale fileMaxWidth ttlSeconds)
  @default_booleans ~w(showLineNumbers wordWrap background)
  @context_keys ~w(agentId sessionId messageChannel agentAccountId)
  @profiles %{
    "standard" => {2, 960, 8_000_000},
    "hq" => {2.5, 1200, 14_000_000},
    "print" => {3, 1400, 24_000_000}
  }
  # ECMAScript WhiteSpace + LineTerminator; deliberately excludes U+0085.
  @trim ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  @spec prepare(map(), map()) :: {:ok, map()} | {:error, :invalid_input}
  def prepare(arguments, resolved) do
    with true <- json?(arguments) and json?(resolved),
         true <- valid_arguments?(arguments),
         true <- valid_resolved?(resolved),
         {:ok, input} <- normalize_input(arguments) do
      context = build_context(Map.get(resolved, "context"))

      if input["kind"] == "before_after" and input["before"] == input["after"] do
        {:ok,
         %{
           "content" => [
             %{
               "type" => "text",
               "text" => "Before and after are identical — no changes to render."
             }
           ],
           "details" => optional(%{"changed" => false}, "context", context)
         }}
      else
        {:ok, plan(arguments, resolved, input, context)}
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp plan(args, resolved, input, context) do
    defaults = resolved["defaults"]
    mode = Map.get(args, "mode", defaults["mode"])
    theme = Map.get(args, "theme", defaults["theme"])
    layout = Map.get(args, "layout", defaults["layout"])
    quality = Map.get(args, "fileQuality", defaults["fileQuality"])
    {profile_scale, profile_width, pixels} = Map.fetch!(@profiles, quality)
    quality_override? = Map.has_key?(args, "fileQuality")
    scale_fallback = if quality_override?, do: profile_scale, else: defaults["fileScale"]
    width_fallback = if quality_override?, do: profile_width, else: defaults["fileMaxWidth"]

    scale =
      case Map.fetch(args, "fileScale") do
        {:ok, value} -> clamp(js_round(value * 100.0) / 100, 1, 4)
        :error -> scale_fallback
      end

    width =
      case Map.fetch(args, "fileMaxWidth") do
        {:ok, value} -> clamp(js_round(value), 640, 2400)
        :error -> width_fallback
      end

    options =
      %{
        "presentation" => Map.merge(defaults, %{"layout" => layout, "theme" => theme}),
        "image" => %{
          "format" => Map.get(args, "fileFormat", defaults["fileFormat"]),
          "qualityPreset" => quality,
          "scale" => scale,
          "maxWidth" => width,
          "maxPixels" => pixels
        },
        "expandUnchanged" => args["expandUnchanged"] == true
      }
      |> optional("languagePackAvailable", Map.get(resolved, "languagePackAvailable"))

    %{
      "input" => input,
      "options" => options,
      "renderTarget" =>
        case mode do
          "view" -> "viewer"
          value when value in ["image", "file"] -> "image"
          _ -> "both"
        end,
      "mode" => mode,
      "ttlMs" =>
        floor(clamp(Map.get(args, "ttlSeconds", defaults["ttlSeconds"]), 1, 21_600) * 1000.0)
    }
    |> optional("context", context)
  end

  defp normalize_input(args) do
    patch = if is_binary(args["patch"]), do: trim(args["patch"])

    if patch not in [nil, ""] do
      title = if is_binary(args["title"]), do: trim(args["title"])

      if not Map.has_key?(args, "before") and not Map.has_key?(args, "after") and
           bounded?(patch, 2 * 1024 * 1024) and bounded?(title, 1024) do
        {:ok, optional(%{"kind" => "patch", "patch" => patch}, "title", title)}
      else
        {:error, :invalid_input}
      end
    else
      before = args["before"]
      after_text = args["after"]
      path = normalize_string(args["path"])
      lang = normalize_string(args["lang"])
      title = normalize_string(args["title"])

      if is_binary(before) and is_binary(after_text) and bounded?(before, 512 * 1024) and
           bounded?(after_text, 512 * 1024) and bounded?(path, 2048) and bounded?(lang, 128) and
           bounded?(title, 1024) do
        {:ok,
         %{"kind" => "before_after", "before" => before, "after" => after_text}
         |> optional("path", path)
         |> optional("lang", lang)
         |> optional("title", title)}
      else
        {:error, :invalid_input}
      end
    end
  end

  defp build_context(context) when is_map(context) do
    result =
      Enum.reduce(@context_keys, %{}, fn key, acc ->
        optional(acc, key, normalize_string(context[key]))
      end)

    if map_size(result) > 0, do: result
  end

  defp build_context(_), do: nil

  defp valid_arguments?(args) when is_map(args) do
    allowed = @strings ++ Map.keys(@numbers) ++ Map.keys(@enums) ++ ["expandUnchanged"]

    Enum.all?(Map.keys(args), &(&1 in allowed)) and
      Enum.all?(@strings, &optional_type?(args, &1, fn value -> is_binary(value) end)) and
      Enum.all?(@enums, fn {key, values} -> optional_type?(args, key, &(&1 in values)) end) and
      Enum.all?(@numbers, fn {key, {low, high}} ->
        optional_type?(args, key, &(is_number(&1) and &1 >= low and &1 <= high))
      end) and optional_type?(args, "expandUnchanged", &is_boolean/1)
  end

  defp valid_arguments?(_), do: false

  defp valid_resolved?(%{"defaults" => defaults} = resolved) when is_map(defaults) do
    required =
      @default_strings ++
        @default_numbers ++
        @default_booleans ++
        Map.keys(@enums) ++
        ["diffIndicators"]

    Enum.sort(Map.keys(defaults)) == Enum.sort(required) and
      Enum.all?(@default_strings, &is_binary(defaults[&1])) and
      Enum.all?(@default_numbers, &is_number(defaults[&1])) and
      Enum.all?(@default_booleans, &is_boolean(defaults[&1])) and
      Enum.all?(@enums, fn {key, values} -> defaults[key] in values end) and
      defaults["diffIndicators"] in ~w(bars classic none) and
      defaults["fontSize"] >= 10 and defaults["fontSize"] <= 24 and
      defaults["lineSpacing"] >= 1 and defaults["lineSpacing"] <= 3 and
      Enum.all?(@numbers, fn {key, {low, high}} ->
        defaults[key] >= low and defaults[key] <= high
      end) and
      Enum.all?(Map.keys(resolved), &(&1 in ~w(defaults context languagePackAvailable))) and
      optional_type?(resolved, "context", &(is_nil(&1) or is_map(&1))) and
      optional_type?(resolved, "languagePackAvailable", &is_boolean/1)
  end

  defp valid_resolved?(_), do: false

  defp optional_type?(map, key, predicate) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> predicate.(value)
    end
  end

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)
  end

  defp json?(_), do: false
  defp bounded?(nil, _max), do: true
  defp bounded?(value, max), do: byte_size(value) <= max
  defp trim(value), do: Regex.replace(@trim, value, "")
  defp normalize_string(value) when is_binary(value), do: case_blank(trim(value))
  defp normalize_string(_), do: nil
  defp case_blank(""), do: nil
  defp case_blank(value), do: value
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp clamp(value, low, high), do: max(low, min(high, value))

  # Preserve binary64 arithmetic before the ECMAScript positive tie rule;
  # for example, 1.005 * 100 is below 100.5 and rounds down to 100.
  defp js_round(value), do: floor(value + 0.5)
end
