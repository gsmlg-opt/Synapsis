defmodule Synapsis.Filesystem.TextReadFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.Local
  alias Synapsis.Filesystem.TextRead

  @moduletag :tmp_dir

  # Independent literal expectations extracted from pinned OpenClaw read.ts/read-page.ts
  # before implementing this owner. These are ordinary successful text reads only.
  test "normalizes a leading BOM and CRLF while retaining the final LF", %{tmp_dir: root} do
    bytes = "\uFEFFalpha\r\nbeta\r\ngamma\r\n"
    File.write!(Path.join(root, "normal.txt"), bytes)

    expected = %{
      content: [%{type: "text", text: "alpha\nbeta\ngamma\n"}],
      details: %{kind: "text", content: "alpha\nbeta\ngamma\n"}
    }

    assert {:ok, ^expected} = TextRead.page(bytes, %{})
    assert {:ok, ^expected} = Local.read_text(root, "normal.txt", %{})
    assert File.read!(Path.join(root, "normal.txt")) == bytes
  end

  test "uses one-based slices and preserves the exact machine continuation", %{tmp_dir: root} do
    bytes = "\uFEFFalpha\r\nbeta\r\ngamma\r\n"
    File.write!(Path.join(root, "normal.txt"), bytes)

    expected = %{
      content: [%{type: "text", text: "beta\n\n[1 more line in file. Use offset=3 to continue.]"}],
      details: %{
        kind: "truncated",
        content: "beta",
        continuation: %{kind: "line", offset: 3, limit: 1},
        truncation: %{
          truncated: true,
          truncatedBy: "lines",
          totalLines: 3,
          totalBytes: 4,
          outputLines: 1,
          outputBytes: 4,
          lastLinePartial: false,
          firstLineExceedsLimit: false,
          maxLines: 1,
          maxBytes: 51200
        }
      }
    }

    args = %{"offset" => 2, "limit" => 1}
    assert {:ok, ^expected} = TextRead.page(bytes, args)
    assert {:ok, ^expected} = Local.read_text(root, "normal.txt", args)

    assert {:ok,
            %{
              content: [%{type: "text", text: "gamma\n"}],
              details: %{kind: "text", content: "gamma\n"}
            }} =
             Local.read_text(root, "normal.txt", %{"offset" => 3, "limit" => 1})
  end

  test "counts selected bytes separately from the file and footer", %{tmp_dir: root} do
    bytes = "one\ntwo\nthree\nfour\n"
    File.write!(Path.join(root, "four.txt"), bytes)

    expected = %{
      content: [
        %{type: "text", text: "one\ntwo\n\n[2 more lines in file. Use offset=3 to continue.]"}
      ],
      details: %{
        kind: "truncated",
        content: "one\ntwo",
        continuation: %{kind: "line", offset: 3, limit: 2},
        truncation: %{
          truncated: true,
          truncatedBy: "lines",
          totalLines: 4,
          totalBytes: 7,
          outputLines: 2,
          outputBytes: 7,
          lastLinePartial: false,
          firstLineExceedsLimit: false,
          maxLines: 2,
          maxBytes: 51200
        }
      }
    }

    assert {:ok, ^expected} = Local.read_text(root, "four.txt", %{"offset" => 1, "limit" => 2})

    assert {:ok,
            %{
              content: [%{type: "text", text: "three\nfour\n"}],
              details: %{kind: "text", content: "three\nfour\n"}
            }} =
             Local.read_text(root, "four.txt", %{"offset" => 3, "limit" => 2})
  end

  test "Unicode cursors count UTF16 units", %{tmp_dir: root} do
    bytes = "A😀中B\n尾\n"
    File.write!(Path.join(root, "unicode.txt"), bytes)

    expected = %{
      content: [%{type: "text", text: "中B\n\n[1 more line in file. Use offset=2 to continue.]"}],
      details: %{
        kind: "truncated",
        content: "中B",
        continuation: %{kind: "line", offset: 2, limit: 1},
        truncation: %{
          truncated: true,
          truncatedBy: "lines",
          totalLines: 2,
          totalBytes: 4,
          outputLines: 1,
          outputBytes: 4,
          lastLinePartial: false,
          firstLineExceedsLimit: false,
          maxLines: 1,
          maxBytes: 51200
        }
      }
    }

    assert {:ok, ^expected} =
             Local.read_text(root, "unicode.txt", %{"offset" => 1, "cursor" => 3, "limit" => 1})

    assert {:ok,
            %{
              content: [%{type: "text", text: "😀中B\n尾\n"}],
              details: %{kind: "text", content: "😀中B\n尾\n"}
            }} =
             Local.read_text(root, "unicode.txt", %{"offset" => 1, "cursor" => 1})

    assert {:ok,
            %{content: [%{type: "text", text: "尾\n"}], details: %{kind: "text", content: "尾\n"}}} =
             Local.read_text(root, "unicode.txt", %{"offset" => 2, "cursor" => 0, "limit" => 1})
  end

  test "empty and blank files have distinct text and raw details", %{tmp_dir: root} do
    File.write!(Path.join(root, "empty.txt"), "")
    File.write!(Path.join(root, "blank.txt"), "\n\n")

    assert {:ok,
            %{
              content: [%{type: "text", text: "File is empty (0 bytes)."}],
              details: %{kind: "text", content: "File is empty (0 bytes)."}
            }} = Local.read_text(root, "empty.txt", %{})

    assert {:ok,
            %{
              content: [%{type: "text", text: "File contains 2 blank lines."}],
              details: %{kind: "text", content: "\n\n"}
            }} = Local.read_text(root, "blank.txt", %{})
  end

  test "preserves lone CR, a non-leading BOM and a natural unterminated last line", %{
    tmp_dir: root
  } do
    bytes = "\uFEFFone\rtwo\r\n\uFEFFthree\n"
    File.write!(Path.join(root, "normalization.txt"), bytes)

    assert {:ok,
            %{
              content: [%{type: "text", text: "one\rtwo\n\uFEFFthree\n"}],
              details: %{kind: "text", content: "one\rtwo\n\uFEFFthree\n"}
            }} = Local.read_text(root, "normalization.txt", %{})

    assert {:ok, %{content: [%{type: "text", text: "尾"}], details: %{kind: "text", content: "尾"}}} =
             TextRead.page("head\n尾", %{"offset" => 2})
  end

  test "reads ordinary text with caller-provided framing", %{tmp_dir: root} do
    File.write!(Path.join(root, "framed.txt"), "hello\n")

    assert {:ok,
            %{
              content: [%{type: "text", text: "Resolved path.\nhello\n"}],
              details: %{kind: "text", content: "hello\n"}
            }} =
             Local.read_text(root, "framed.txt", %{}, prefix: "Resolved path.\n")
  end

  test "internal domain pages retain their existing zero-based contract", %{tmp_dir: root} do
    File.write!(Path.join(root, "domain.txt"), "one\ntwo\nthree\n")

    assert {:ok, %{content: "two\n", offset: 1, next_offset: 2}} =
             Local.perform(root, :file_read, %{
               "path" => "domain.txt",
               "offset" => 1,
               "limit" => 1
             })

    assert {:ok, %{content: "two\n", offset: 1, next_offset: 2}} =
             Local.page_content("one\ntwo\nthree\n", "domain.txt", %{"offset" => 1, "limit" => 1})
  end
end
