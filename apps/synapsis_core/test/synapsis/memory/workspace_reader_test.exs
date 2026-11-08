defmodule Synapsis.Memory.WorkspaceReaderTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.WorkspaceReader

  @moduletag :tmp_dir

  test "lists only canonical and nested Markdown, without creating files", %{tmp_dir: root} do
    assert {:ok, %{status: "ok", files: []}} = WorkspaceReader.list(root)

    assert {:ok, %{status: "ok", ranking: "lexical", results: []}} =
             WorkspaceReader.search(root, "memory")

    assert File.ls!(root) == []
    put(root, "MEMORY.md", "# Durable memory\n")
    put(root, "memory/nested/2026-10-24.md", "中文日记\n")
    put(root, "memory/nested/ignored.txt", "unrelated")
    put(root, "memory.md", "lowercase is not canonical")
    put(root, "README.md", "unrelated")
    put(root, "other/secret.md", "unrelated")

    assert {:ok,
            %{
              status: "ok",
              files: [
                %{path: "MEMORY.md", size: 17},
                %{path: "memory/nested/2026-10-24.md", size: 13}
              ]
            }} = WorkspaceReader.list(root)
  end

  test "plain Markdown needs no YAML and reads preserve actual lines", %{tmp_dir: root} do
    put(root, "MEMORY.md", "# Memory\n第一行\n第二行\nlast")

    assert {:ok,
            %{
              status: "ok",
              path: "MEMORY.md",
              from: 1,
              to: 2,
              content: "# Memory\n第一行\n",
              truncated: true,
              next_from: 3
            }} = WorkspaceReader.read(root, "MEMORY.md", lines: 2)

    assert {:ok,
            %{
              from: 3,
              to: 4,
              content: "第二行\nlast",
              truncated: false,
              next_from: nil
            }} = WorkspaceReader.read(root, "MEMORY.md", from: 3, lines: 2)

    assert {:ok, %{from: 10, to: 9, content: "", truncated: false, next_from: nil}} =
             WorkspaceReader.read(root, "MEMORY.md", from: 10)
  end

  test "empty Markdown succeeds and a final newline adds no phantom line", %{tmp_dir: root} do
    put(root, "MEMORY.md", "")

    assert {:ok, %{from: 1, to: 0, content: "", truncated: false}} =
             WorkspaceReader.read(root, "MEMORY.md")

    put(root, "MEMORY.md", "first\n\n")

    assert {:ok, %{from: 1, to: 2, content: "first\n\n", truncated: false}} =
             WorkspaceReader.read(root, "MEMORY.md")
  end

  test "character cap fits complete lines and resumes at the first omitted line", %{tmp_dir: root} do
    first = String.duplicate("a", 5_999) <> "\n"
    second = String.duplicate("b", 5_999) <> "\n"
    put(root, "MEMORY.md", first <> second <> "last line\n")

    assert {:ok,
            %{
              from: 1,
              to: 2,
              content: content,
              truncated: true,
              next_from: 3,
              partial_line: false,
              notice: nil
            }} = WorkspaceReader.read(root, "MEMORY.md")

    assert content == first <> second
    assert String.length(content) == 12_000

    assert {:ok, %{from: 3, to: 3, content: "last line\n", truncated: false, next_from: nil}} =
             WorkspaceReader.read(root, "MEMORY.md", from: 3)
  end

  test "character cap counts Unicode characters rather than UTF8 bytes", %{tmp_dir: root} do
    first = String.duplicate("记忆", 3_000) <> "\n"
    put(root, "MEMORY.md", first <> first)

    assert {:ok,
            %{from: 1, to: 1, content: ^first, truncated: true, next_from: 2, partial_line: false}} =
             WorkspaceReader.read(root, "MEMORY.md")

    assert byte_size(first) > 12_000
    assert String.valid?(first)

    assert {:ok, %{from: 2, to: 2, content: ^first, truncated: false, next_from: nil}} =
             WorkspaceReader.read(root, "MEMORY.md", from: 2)
  end

  test "oversized first line is explicitly partial and cannot skip its unread remainder",
       %{tmp_dir: root} do
    put(root, "MEMORY.md", String.duplicate("😀", 8_000) <> "unread remainder\nnext line")

    assert {:ok,
            %{
              from: 1,
              to: 1,
              content: content,
              truncated: true,
              next_from: nil,
              partial_line: true,
              notice: notice
            }} = WorkspaceReader.read(root, "MEMORY.md")

    assert content == String.duplicate("😀", 6_000)
    assert String.valid?(content)
    assert notice =~ "within a source line"
    assert notice =~ "Read the source file"
    refute content =~ "unread remainder"
    refute content =~ "next line"
  end

  test "UTF16 cap never splits an astral character at its surrogate boundary", %{tmp_dir: root} do
    prefix = String.duplicate("a", 11_999)
    put(root, "MEMORY.md", prefix <> "😀suffix")

    assert {:ok, %{content: ^prefix, truncated: true, next_from: nil, partial_line: true}} =
             WorkspaceReader.read(root, "MEMORY.md")
  end

  test "lexical search cites real lines and searches before snippet truncation", %{tmp_dir: root} do
    put(root, "MEMORY.md", "First\nCONCORD stores turns\n中文记忆\n")
    put(root, "memory/nested/notes.md", "ignored\n" <> String.duplicate("前缀", 600) <> "needle")

    assert {:ok,
            %{
              status: "ok",
              ranking: "lexical",
              results: [%{path: "MEMORY.md", from: 2, to: 2, snippet: "CONCORD stores turns\n"}]
            }} = WorkspaceReader.search(root, "concord")

    assert {:ok, %{results: [%{path: "MEMORY.md", from: 3, to: 3}]}} =
             WorkspaceReader.search(root, "中文")

    assert {:ok, %{results: [%{path: "memory/nested/notes.md", from: 2, to: 2} = result]}} =
             WorkspaceReader.search(root, "needle")

    assert String.valid?(result.snippet)
    assert byte_size(result.snippet) <= 2_048
    assert result.snippet =~ "needle"
  end

  test "search order and limits are deterministic", %{tmp_dir: root} do
    put(root, "memory/z.md", "match\nmatch")
    put(root, "memory/a.md", "match\nmatch")

    assert {:ok, %{results: [%{path: "memory/a.md", from: 1}]}} =
             WorkspaceReader.search(root, "match", limit: 1)

    assert {:ok, %{results: results}} = WorkspaceReader.search(root, "match")

    assert Enum.map(results, &{&1.path, &1.from}) ==
             [{"memory/a.md", 1}, {"memory/a.md", 2}, {"memory/z.md", 1}, {"memory/z.md", 2}]
  end

  test "distinguishes absent workspace from missing memory files", %{tmp_dir: root} do
    missing = Path.join(root, "missing")
    assert {:error, :unavailable} = WorkspaceReader.list(missing)
    assert {:error, :unavailable} = WorkspaceReader.search(missing, "a")
    assert {:error, :unavailable} = WorkspaceReader.read(missing, "MEMORY.md")
    assert {:error, :not_found} = WorkspaceReader.read(root, "MEMORY.md")
    assert {:error, :not_found} = WorkspaceReader.read(root, "memory/missing.md")
  end

  test "validates roots, query, options and paths without raising", %{tmp_dir: root} do
    for path <- [
          "../secret.md",
          "/tmp/secret.md",
          "README.md",
          "memory.md",
          "memory/a.txt",
          "memory/../MEMORY.md",
          "memory//a.md",
          "memory/./a.md",
          "memory/a\\b.md",
          "memory/a\0.md",
          <<255>>,
          nil,
          %{}
        ] do
      assert {:error, :invalid_input} = WorkspaceReader.read(root, path)
    end

    for bad <- [nil, %{}, [:bad], [unknown: true], [deadline: 1, deadline: 2]] do
      assert {:error, :invalid_input} = WorkspaceReader.list(root, bad)
      assert {:error, :invalid_input} = WorkspaceReader.search(root, "a", bad)
      assert {:error, :invalid_input} = WorkspaceReader.read(root, "MEMORY.md", bad)
    end

    for bad <- [nil, "relative", <<255>>, "/tmp/\0bad"] do
      assert {:error, :invalid_input} = WorkspaceReader.list(bad)
    end

    for query <- [nil, 1, "", <<255>>, String.duplicate("x", 2_049)] do
      assert {:error, :invalid_input} = WorkspaceReader.search(root, query)
    end

    for opts <- [[from: 0], [from: "1"], [lines: 0], [lines: 121], [deadline: :bad]] do
      assert {:error, :invalid_input} = WorkspaceReader.read(root, "MEMORY.md", opts)
    end

    assert {:error, :invalid_input} = WorkspaceReader.search(root, "a", limit: 21)
    assert {:error, :invalid_input} = WorkspaceReader.search(root, "a", limit: 0)
  end

  test "rejects symlinked roots, directories and Markdown leaves", %{tmp_dir: root} do
    put(root, "MEMORY.md", "owned")
    put(root, "memory/nested/a.md", "nested")
    link = root <> "-link"
    File.ln_s!(root, link)
    on_exit(fn -> File.rm(link) end)
    assert {:error, :unsafe_path} = WorkspaceReader.read(link, "MEMORY.md")

    File.ln_s!(Path.join(root, "memory/nested"), Path.join(root, "memory/alias"))
    assert {:error, :unsafe_path} = WorkspaceReader.read(root, "memory/alias/a.md")
    assert {:error, :unsafe_path} = WorkspaceReader.list(root)
    File.rm!(Path.join(root, "memory/alias"))
    File.ln_s!(Path.join(root, "MEMORY.md"), Path.join(root, "memory/link.md"))
    assert {:error, :unsafe_path} = WorkspaceReader.read(root, "memory/link.md")
    assert {:error, :unsafe_path} = WorkspaceReader.search(root, "owned")
  end

  test "rejects hardlinked files and oversized files", %{tmp_dir: root} do
    put(root, "MEMORY.md", "owned")
    File.ln!(Path.join(root, "MEMORY.md"), Path.join(root, "hardlink"))
    assert {:error, :unsafe_path} = WorkspaceReader.read(root, "MEMORY.md")
    assert {:error, :unsafe_path} = WorkspaceReader.list(root)
    File.rm!(Path.join(root, "hardlink"))

    put(root, "MEMORY.md", String.duplicate("x", 65_537))
    assert {:error, :file_limit} = WorkspaceReader.read(root, "MEMORY.md")
    assert {:error, :file_limit} = WorkspaceReader.search(root, "x")
  end

  test "counts nested directory entries, including unrelated entries, toward scan limit",
       %{tmp_dir: root} do
    for number <- 1..128, do: put(root, "memory/nested/#{number}.txt", "unrelated")
    assert {:error, :scan_limit} = WorkspaceReader.list(root)
    assert {:error, :scan_limit} = WorkspaceReader.search(root, "nothing")
  end

  test "does not scan unrelated workspace directories", %{tmp_dir: root} do
    for number <- 1..140, do: put(root, "other/#{number}.md", "unrelated")
    put(root, "MEMORY.md", "real")
    assert {:ok, %{files: [%{path: "MEMORY.md"}]}} = WorkspaceReader.list(root)
  end

  test "enforces JSON output budget and explicit deadline", %{tmp_dir: root} do
    put(root, "MEMORY.md", String.duplicate("\t", 40_000))

    assert {:ok, %{content: content, truncated: true, partial_line: true, next_from: nil}} =
             WorkspaceReader.read(root, "MEMORY.md")

    assert content == String.duplicate("\t", 12_000)
    put(root, "MEMORY.md", String.duplicate(<<1>>, 40_000))
    assert {:error, :output_limit} = WorkspaceReader.read(root, "MEMORY.md")

    assert {:error, :timeout} =
             WorkspaceReader.list(root, deadline: System.monotonic_time(:millisecond) - 1)
  end

  test "timeout terminates even a suspended filesystem worker", %{tmp_dir: root} do
    put(root, "MEMORY.md", "remember")
    caller = traced_caller(root, self())
    send(caller, :go)
    assert_receive {:trace, reader, :call, {File, :open, _}}, 1_000
    :erlang.suspend_process(reader)
    on_exit(fn -> Process.exit(reader, :kill) end)
    monitor = Process.monitor(reader)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1_500
    assert_receive {:result, {:error, :timeout}}, 1_000
  end

  test "owner death terminates even a suspended filesystem worker", %{tmp_dir: root} do
    put(root, "MEMORY.md", "remember")
    caller = traced_caller(root, self())
    send(caller, :go)
    assert_receive {:trace, reader, :call, {File, :open, _}}, 1_000
    :erlang.suspend_process(reader)
    on_exit(fn -> Process.exit(reader, :kill) end)
    monitor = Process.monitor(reader)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 500
  end

  defp traced_caller(root, test) do
    # Receive the filesystem call trace before the ordinary-priority reader can
    # finish, so suspension tests do not depend on filesystem scheduling speed.
    Process.flag(:priority, :high)

    caller =
      :erlang.spawn_opt(
        fn ->
          receive do
            :go -> send(test, {:result, WorkspaceReader.read(root, "MEMORY.md")})
          end
        end,
        [{:priority, :normal}]
      )

    :erlang.trace_pattern({File, :open, 2}, true, [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.exit(caller, :kill)
    end)

    caller
  end

  defp put(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
