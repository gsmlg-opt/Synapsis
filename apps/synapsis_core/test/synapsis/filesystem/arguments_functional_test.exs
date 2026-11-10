defmodule Synapsis.Filesystem.ArgumentsFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Filesystem.Arguments

  # Independently frozen literal expectations from OpenClaw
  # 488631c18fae7cc541ba8fc8beff6cbb0438787b:
  # edit.ts:67-115, json-parse.ts:5-94, agent-tools.params.ts:21-27,96-116.
  # No reference runner or production helper constructs expected values.

  test "projects map metadata while retaining ordered literal paths and replacement text" do
    input = %{
      "path" => "  @reports/Plan.DOCcodex</arg_value>>  ",
      "file_path" => "alias.txt",
      "old_string" => "alias before",
      "new_string" => "alias after",
      "reason" => "model explanation",
      "edits" => [
        %{"oldText" => "first", "newText" => "FIRST", "reason" => "one"},
        %{"oldText" => "second", "newText" => "SECOND", "line" => 7},
        %{
          "oldText" => "literal </arg_value>> .doccodex @name ~/x file:///tmp/x",
          "newText" => "literal </arg_value>> .pptcodex @next ~/y file:///tmp/y",
          "metadata" => %{"source" => "model"}
        }
      ]
    }

    expected = %{
      "path" => "  @reports/Plan.DOCcodex</arg_value>>  ",
      "edits" => [
        %{"oldText" => "first", "newText" => "FIRST"},
        %{"oldText" => "second", "newText" => "SECOND"},
        %{
          "oldText" => "literal </arg_value>> .doccodex @name ~/x file:///tmp/x",
          "newText" => "literal </arg_value>> .pptcodex @next ~/y file:///tmp/y"
        }
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "promotes a complete legacy pair and preserves an empty replacement" do
    expected = %{
      "path" => "notes.txt",
      "edits" => [%{"oldText" => "remove me", "newText" => ""}]
    }

    assert {:ok, ^expected} =
             Arguments.prepare_edit(%{
               "path" => "notes.txt",
               "oldText" => "remove me",
               "newText" => "",
               "reason" => "delete"
             })
  end

  test "appends a legacy pair after the batch when only its old text already occurs" do
    input = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "same", "newText" => "first"},
        %{"oldText" => "tail", "newText" => "last"}
      ],
      "oldText" => "same",
      "newText" => "second"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "same", "newText" => "first"},
        %{"oldText" => "tail", "newText" => "last"},
        %{"oldText" => "same", "newText" => "second"}
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "retains repeated existing pairs without appending an already present legacy pair" do
    input = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "same", "newText" => "value", "reason" => "first"},
        %{"oldText" => "other", "newText" => "OTHER"},
        %{"oldText" => "same", "newText" => "value", "reason" => "repeated"}
      ],
      "oldText" => "same",
      "newText" => "value"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "same", "newText" => "value"},
        %{"oldText" => "other", "newText" => "OTHER"},
        %{"oldText" => "same", "newText" => "value"}
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "compares complete legacy pairs with exact case and whitespace" do
    input = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "Before", "newText" => "after"},
        %{"oldText" => "before ", "newText" => "after"},
        %{"oldText" => "before", "newText" => "after "}
      ],
      "oldText" => "before",
      "newText" => "after"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "Before", "newText" => "after"},
        %{"oldText" => "before ", "newText" => "after"},
        %{"oldText" => "before", "newText" => "after "},
        %{"oldText" => "before", "newText" => "after"}
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "parses serialized arrays before metadata projection and ordered legacy append" do
    input = %{
      "path" => "notes.txt",
      "edits" =>
        ~S([{"oldText":"alpha","newText":"ALPHA","reason":"one"},{"oldText":"beta","newText":"","line":2}]),
      "oldText" => "tail",
      "newText" => "TAIL",
      "reason" => "top level"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "alpha", "newText" => "ALPHA"},
        %{"oldText" => "beta", "newText" => ""},
        %{"oldText" => "tail", "newText" => "TAIL"}
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "recognizes an existing exact legacy pair after parsing a serialized array" do
    input = %{
      "path" => "notes.txt",
      "edits" =>
        ~S([{"oldText":"same","newText":"value","reason":"existing"},{"oldText":"tail","newText":"TAIL"}]),
      "oldText" => "same",
      "newText" => "value"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{"oldText" => "same", "newText" => "value"},
        %{"oldText" => "tail", "newText" => "TAIL"}
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "preserves valid serialized control escapes after a Windows-looking prefix" do
    input = %{
      "path" => "notes.txt",
      "edits" =>
        ~S([{"oldText":"C:\new\temp\r\b\f","newText":"quote:\" slash:\/ backslash:\\ unicode:\u4e2d\uD83D\uDE00"}])
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{
          "oldText" => "C:\new\temp\r\b\f",
          "newText" => "quote:\" slash:/ backslash:\\ unicode:中😀"
        }
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "repairs every raw JSON string control inside a complete serialized array" do
    input = %{
      "path" => "notes.txt",
      "edits" =>
        "[{\"oldText\":\"before\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1Fend\",\"newText\":\"after\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1Fend\"}]"
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [
        %{
          "oldText" =>
            "before\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1Fend",
          "newText" =>
            "after\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1Fend"
        }
      ]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "repairs invalid backslashes as literal text inside a complete serialized array" do
    input = %{
      "path" => "notes.txt",
      "edits" => ~S([{"oldText":"left\q\z","newText":"right\u12x4\_"}])
    }

    expected = %{
      "path" => "notes.txt",
      "edits" => [%{"oldText" => "left\\q\\z", "newText" => "right\\u12x4\\_"}]
    }

    assert {:ok, ^expected} = Arguments.prepare_edit(input)
  end

  test "repairs exactly the source Office extension families and case variants" do
    rows = [
      {"report.docodex", "report.docx"},
      {"report.doccodex", "report.docx"},
      {"report.docxodex", "report.docx"},
      {"report.docxcodex", "report.docx"},
      {"deck.pptodex", "deck.pptx"},
      {"deck.pptcodex", "deck.pptx"},
      {"deck.pptxodex", "deck.pptx"},
      {"deck.pptxcodex", "deck.pptx"},
      {"sheet.xlsodex", "sheet.xlsx"},
      {"sheet.xlscodex", "sheet.xlsx"},
      {"sheet.xlsxodex", "sheet.xlsx"},
      {"sheet.xlsxcodex", "sheet.xlsx"},
      {"Report.DOCXCODEX", "Report.docx"},
      {"Deck.PpTcOdEx", "Deck.pptx"},
      {"Sheet.XLSODEX", "Sheet.xlsx"}
    ]

    for {input, expected} <- rows do
      assert {:ok, ^expected} = Arguments.normalize_path(input)
    end
  end

  test "strips only the exact terminal XML argument suffix" do
    rows = [
      {"notes.txt</arg_value>>", "notes.txt"},
      {"notes.txt</arg_value>>>>", "notes.txt"},
      {"dir/</arg_value>>/notes.txt</arg_value>>>", "dir/</arg_value>>/notes.txt"}
    ]

    for {input, expected} <- rows do
      assert {:ok, ^expected} = Arguments.normalize_path(input)
    end
  end

  test "strips the XML suffix before repairing an Office extension" do
    rows = [
      {"report.doccodex</arg_value>>", "report.docx"},
      {"Deck.PPTXODEX</arg_value>>>>", "Deck.pptx"},
      {"sheet.xlsxcodex</arg_value>>>", "sheet.xlsx"}
    ]

    for {input, expected} <- rows do
      assert {:ok, ^expected} = Arguments.normalize_path(input)
    end
  end

  test "retains ordinary lexical paths without general replacement or expansion" do
    rows = [
      {"@notes.txt", "@notes.txt"},
      {"@@notes.txt", "@@notes.txt"},
      {"./@notes.txt", "./@notes.txt"},
      {"~/notes.txt", "~/notes.txt"},
      {"file:///tmp/notes.txt", "file:///tmp/notes.txt"},
      {"  notes.txt  ", "  notes.txt  "},
      {"notes.docx", "notes.docx"},
      {"dir/report.doccodex/notes.txt", "dir/report.doccodex/notes.txt"},
      {"report.doccodex.backup", "report.doccodex.backup"},
      {"notes.txt</arg_value>", "notes.txt</arg_value>"},
      {"notes.txt</ARG_VALUE>>", "notes.txt</ARG_VALUE>>"},
      {"notes.txt</arg_value>>.backup", "notes.txt</arg_value>>.backup"},
      {"report.doccodex ", "report.doccodex "},
      {"笔记/😀.txt", "笔记/😀.txt"}
    ]

    for {input, expected} <- rows do
      assert {:ok, ^expected} = Arguments.normalize_path(input)
    end
  end
end
