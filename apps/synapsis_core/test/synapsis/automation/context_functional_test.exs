defmodule Synapsis.Automation.ContextFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Automation.Context
  alias Synapsis.{Message, Part}

  test "host and runtime messages retain chronological role and normalized text" do
    messages = [
      %Message{role: "user", parts: [%Part.Text{content: "  Hello\n world \t"}]},
      %{role: :assistant, content: [%{type: :text, text: "Ready"}, %{type: :text, text: "now"}]},
      %{"role" => "user", "parts" => [%{"type" => "text", "text" => "原文"}]}
    ]

    assert Context.format(messages) ==
             "Recent conversation:\n- User: Hello world\n- Assistant: Ready now\n- User: 原文"
  end

  test "mixed native parts contribute only the user and assistant text" do
    messages = [
      %{role: :system, content: "System instruction"},
      %{role: :tool, content: "Tool output"},
      %Message{
        role: "assistant",
        parts: [
          %Part.Reasoning{content: "Planning"},
          %Part.Text{content: "Visible"},
          %Part.Image{media_type: "image/png", data: "aW1hZ2U="},
          %Part.ToolUse{tool: "exec", tool_use_id: "call", input: %{}},
          %Part.ToolResult{tool_use_id: "call", content: "Execution result"}
        ]
      },
      %{"role" => "user", "content" => [%{"type" => "text", "text" => "Continue"}]}
    ]

    assert Context.format(messages) ==
             "Recent conversation:\n- Assistant: Visible\n- User: Continue"
  end

  test "the ten newest visible messages determine the context" do
    messages = for n <- 1..12, do: %{role: :user, content: "Message #{n}"}

    expected =
      ["Recent conversation:" | for(n <- 3..12, do: "- User: Message #{n}")]
      |> Enum.join("\n")

    assert Context.format(messages) == expected
  end

  test "a block keeps the newest complete lines within fourteen hundred UTF16 units" do
    messages = for n <- 1..8, do: %{role: :user, content: "#{n}" <> String.duplicate("x", 300)}

    expected_lines = for n <- 3..8, do: "- User: #{n}" <> String.duplicate("x", 208) <> "..."
    block = Context.format(messages)

    assert block == Enum.join(["Recent conversation:" | expected_lines], "\n")
    assert utf16_length(block) <= 1_400

    assert utf16_length(
             Enum.join(["- User: 2" <> String.duplicate("x", 208) <> "...", block], "\n")
           ) >
             1_400
  end

  test "UTF16 line truncation preserves emoji pairs and uses role-specific prefix widths" do
    block =
      Context.format([
        %{role: :user, content: String.duplicate("😀", 110)},
        %{role: :assistant, content: String.duplicate("𠮷", 110)}
      ])

    assert block ==
             "Recent conversation:\n- User: " <>
               String.duplicate("😀", 104) <>
               "...\n- Assistant: " <> String.duplicate("𠮷", 102) <> "..."

    assert Enum.all?(String.split(block, "\n") |> tl(), &(utf16_length(&1) <= 220))
  end

  test "UTF16 boundaries count combining code points independently and normalize Unicode space" do
    text = String.duplicate("e\u0301", 110)

    assert Context.format([%{role: :user, content: text}]) ==
             "Recent conversation:\n- User: " <> String.duplicate("e\u0301", 104) <> "e..."

    assert Context.format([%{role: :user, content: "\uFEFF你好\u00A0\u2003世界\u2028"}]) ==
             "Recent conversation:\n- User: 你好 世界"
  end

  test "literal next-line characters remain ordinary text at edges and truncation boundaries" do
    assert Context.format([%{role: :user, content: "\u0085word\u0085"}]) ==
             "Recent conversation:\n- User: \u0085word\u0085"

    assert Context.format([
             %{role: :user, content: String.duplicate("x", 208) <> "\u0085yyyy"}
           ]) == "Recent conversation:\n- User: " <> String.duplicate("x", 208) <> "\u0085..."
  end

  test "the raw message window is bounded before role and text projection" do
    messages =
      [%{role: :user, content: "Outside raw window"}] ++
        List.duplicate(%{role: :tool, content: "Ordinary tool observation"}, 219) ++
        [%{role: :assistant, content: "Newest answer"}]

    assert Context.format(messages) == "Recent conversation:\n- Assistant: Newest answer"
    assert Context.format([]) == nil
  end

  test "the UTF8 text budget retains the newest complete messages at exactly256KiB" do
    messages =
      for n <- 1..5,
          do: %{role: :user, content: "#{n}" <> String.duplicate("x", 65_535)}

    expected =
      [
        "Recent conversation:"
        | for(n <- 2..5, do: "- User: #{n}" <> String.duplicate("x", 208) <> "...")
      ]
      |> Enum.join("\n")

    assert Context.format(messages) == expected
  end

  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)
end
