defmodule Synapsis.Filesystem.ReadContentFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.{Local, ReadContent}
  alias Synapsis.Filesystem.Planner.PortSession

  @moduletag :tmp_dir
  @reference_commit "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @runtime %{
    "node" => "24.22.1",
    "v8" => "13.6.233.17-node.58",
    "unicode" => "17.0",
    "icu" => "78.3",
    "cldr" => "48.0",
    "platform" => "linux",
    "arch" => "x64"
  }
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  @pdf_advice "Read did not return file contents because it detected a binary document [application/pdf]. Use an available document parser or converter, or convert the file to text, Markdown, or CSV, then read the converted file."

  # Frozen ordinary source vectors; no production function constructs an oracle.
  # Default local UTF16 decoding: windows-encoding.ts:177-214. Output text and
  # image/document details: pinned read.ts:75-87,470-510,542-546,604-612.
  setup_all do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute
    {:ok, node: node}
  end

  test "real local decoder handles UTF16 BOMs replacement and source-byte empty notices", ctx do
    rows = [
      {<<255, 254, 104, 0, 105, 0, 10, 0>>, "hi\n"},
      {<<254, 255, 0, 104, 0, 105, 0, 10>>, "hi\n"},
      {<<99, 97, 102, 233, 10>>, "caf\uFFFD\n"},
      {"\uFEFFhello\r\nworld\r", "hello\nworld\r"},
      {<<255, 254>>, "File contains no readable text (2 bytes)."}
    ]

    for {bytes, text} <- rows do
      expected = text_result(text)
      assert {:ok, ^expected} = ReadContent.prepare(bytes, %{}, options(ctx))
      assert_retired()
    end
  end

  test "pages decoded text once with exact continuation UTF16 cursor and verbatim prefix", ctx do
    expected = %{
      content: [
        %{
          type: "text",
          text: "Resolved.\ntwo\n\n[1 more line in file. Use offset=3 to continue.]"
        }
      ],
      details: %{
        kind: "truncated",
        content: "two",
        continuation: %{kind: "line", offset: 3, limit: 1},
        truncation: %{
          truncated: true,
          truncatedBy: "lines",
          totalLines: 3,
          totalBytes: 3,
          outputLines: 1,
          outputBytes: 3,
          lastLinePartial: false,
          firstLineExceedsLimit: false,
          maxLines: 1,
          maxBytes: 51_190
        }
      }
    }

    assert {:ok, ^expected} =
             ReadContent.prepare(
               "\uFEFFone\r\ntwo\r\nthree\r\n",
               %{"offset" => 2, "limit" => 1},
               options(ctx, prefix: "Resolved.\n")
             )

    assert_retired()

    expected_cursor = %{
      content: [%{type: "text", text: "Frame:中B\n尾\n"}],
      details: %{kind: "text", content: "中B\n尾\n"}
    }

    assert {:ok, ^expected_cursor} =
             ReadContent.prepare(
               "A😀中B\n尾\n",
               %{"cursor" => 3},
               options(ctx, prefix: "Frame:", decode_mode: :utf8)
             )

    assert_retired()
  end

  test "Local captures real immutable bytes and present optional files without changing source files",
       ctx do
    rows = [
      {"utf16.bin", <<255, 254, 104, 0, 105, 0, 10, 0>>, text_result("hi\n")},
      {"picture.bin", Base.decode64!(@png), image_result(@png, "Read image file [image/png]")}
    ]

    for {name, bytes, expected} <- rows do
      target = Path.join(ctx.tmp_dir, name)
      File.write!(target, bytes)
      original = File.stat!(target)

      assert {:ok, ^expected} =
               Local.read_file(ctx.tmp_dir, name, %{"optional" => true}, options(ctx))

      assert_retired()
      assert File.read!(target) == bytes

      assert Map.take(File.stat!(target), [:inode, :mtime, :ctime, :size]) ==
               Map.take(original, [:inode, :mtime, :ctime, :size])
    end
  end

  test "image and byte-detected document framing becomes complete source details", ctx do
    image_text = "Image frame.\nRead image file [image/png]"
    expected_image = image_result(@png, image_text)

    assert {:ok, ^expected_image} =
             ReadContent.prepare(
               Base.decode64!(@png),
               %{},
               options(ctx, prefix: "Image frame.\n", auto_resize_images: false)
             )

    assert_retired()

    omitted =
      text_result(
        "Image frame.\nRead image file [image/png]\n[Current model does not support images. The image will be omitted from this request.]"
      )

    assert {:ok, ^omitted} =
             ReadContent.prepare(
               Base.decode64!(@png),
               %{},
               options(ctx, prefix: "Image frame.\n", model_has_vision: false)
             )

    assert_retired()
    expected_pdf = text_result("Document frame:" <> @pdf_advice)

    assert {:ok, ^expected_pdf} =
             ReadContent.prepare(
               "%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF",
               %{},
               options(ctx, prefix: "Document frame:")
             )

    assert_retired()
  end

  test "real read transport returns the full pinned envelope before normal OS and broker retirement",
       ctx do
    assert {:ok, broker} =
             PortSession.start_link(
               owner_pid: self(),
               caller_pid: self(),
               node_executable: ctx.node,
               helper_path: Path.join(:code.priv_dir(:synapsis_core), "filesystem_read/stdio.mjs")
             )

    assert %{phase: :dormant, os_pid: nil} = PortSession.status(broker)
    monitor = Process.monitor(broker)

    # Harness cleanup belongs to this test alone; passing calls close normally.
    on_exit(fn ->
      if Process.alive?(broker), do: PortSession.close(broker)
    end)

    request = %{
      "protocol" => 1,
      "id" => "batch208:ordinary-read",
      "operation" => "read_content",
      "input" => %{
        "bytes" => Base.encode64("\uFEFFhello\r\nworld\r"),
        "autoResizeImages" => true,
        "decodeMode" => "local"
      }
    }

    expected = %{
      "protocol" => 1,
      "id" => "batch208:ordinary-read",
      "referenceCommit" => @reference_commit,
      "codecVersions" => %{
        "rastermill" => "0.4.0",
        "photon" => "0.3.4",
        "fileType" => "22.1.1"
      },
      "runtime" => @runtime,
      "result" => %{"kind" => "text", "text" => "\uFEFFhello\r\nworld\r"}
    }

    deadline = System.monotonic_time(:millisecond) + 5_000
    assert {:ok, ^expected} = PortSession.plan(broker, request, deadline)
    status = PortSession.status(broker)
    assert_completed(status)
    assert {:ok, ^status} = PortSession.close(broker)
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1_000
    refute Process.alive?(broker)
  end

  defp options(ctx, extra \\ []) do
    Keyword.merge([node_executable: ctx.node, observer_pid: self()], extra)
  end

  defp text_result(text),
    do: %{content: [%{type: "text", text: text}], details: %{kind: "text", content: text}}

  defp image_result(data, text),
    do: %{
      content: [%{type: "text", text: text}, %{type: "image", data: data, mimeType: "image/png"}],
      details: %{kind: "image", content: text, mimeType: "image/png"}
    }

  defp assert_retired do
    assert_receive {:filesystem_planner, broker, status}, 1_000
    assert_completed(status)
    refute Process.alive?(broker)
  end

  defp assert_completed(status) do
    assert %{
             phase: :settled,
             outcome: :completed,
             cleanup_confirmed: true,
             exit_status: 0,
             port_released: true,
             os_pid: os_pid,
             port: port
           } = status

    assert is_integer(os_pid) and os_pid > 0
    assert is_port(port)
    assert Port.info(port) == nil
    refute File.exists?("/proc/#{os_pid}")
  end
end
