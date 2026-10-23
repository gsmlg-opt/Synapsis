defmodule Synapsis.Memory.ScopedReaderTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.{FileAdapter, ScopedReader}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.fetch_env(:synapsis_core, :memory_dir)
    previous_env = System.get_env("SYNAPSIS_MEMORY_DIR")
    System.delete_env("SYNAPSIS_MEMORY_DIR")
    Application.put_env(:synapsis_core, :memory_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_core, :memory_dir, value)
        :error -> Application.delete_env(:synapsis_core, :memory_dir)
      end

      if previous_env, do: System.put_env("SYNAPSIS_MEMORY_DIR", previous_env)
    end)

    %{root: root, scope: %{project_id: "project-a", session_id: "session-a", selector: :project}}
  end

  test "reads actual stored project records without changing files or access stats", ctx do
    store("decision-1", "project-a", "Use Concord for durable state")
    store("foreign", "project-b", "private foreign state")
    File.mkdir_p!(Path.join(ctx.root, "session/session-a"))
    File.write!(Path.join(ctx.root, "session/session-a/broken.md"), "invalid session secret")
    before = snapshot(ctx.root)

    assert {:ok, %{status: "ok", ranking: "lexical", results: [record]}} =
             ScopedReader.search(ctx.scope, "Concord")

    assert %{
             memory_id: "decision-1",
             title: "Architecture",
             summary: "Use Concord for durable state",
             tags: ["storage"],
             citation: %{memory_id: "decision-1", scope: "project", scope_id: "project-a"}
           } = record

    refute Map.has_key?(record, :detail)
    refute Map.has_key?(record.citation, :path)
    assert {:ok, %{status: "ok", record: ^record}} = ScopedReader.read(ctx.scope, "decision-1")
    assert {:error, :not_found} = ScopedReader.read(ctx.scope, "foreign")
    assert snapshot(ctx.root) == before
  end

  test "fails closed on unsupported ownership and traversal", ctx do
    for scope <- [%{ctx.scope | selector: :session}, %{ctx.scope | selector: :shared}] do
      assert {:error, :unsupported_scope} = ScopedReader.search(scope, "anything")
    end

    assert {:error, :invalid_scope} =
             ScopedReader.search(%{ctx.scope | project_id: "../project-b"}, "a")

    assert {:error, :invalid_memory_id} = ScopedReader.read(ctx.scope, "../foreign")
    assert {:error, :invalid_input} = ScopedReader.search(ctx.scope, "a", limit: 21)
  end

  test "distinguishes unavailable roots, empty owned collections and missing records", ctx do
    assert {:error, :unavailable} =
             ScopedReader.search(ctx.scope, "a", root: Path.join(ctx.root, "missing"))

    assert {:ok, %{results: []}} = ScopedReader.search(ctx.scope, "a")
    assert {:error, :not_found} = ScopedReader.read(ctx.scope, "missing")
  end

  test "rejects symlinked roots, scope directories, leaves and hardlinked records", ctx do
    store("one", "project-a", "owned")
    path = Path.join(ctx.root, "project/project-a/one.md")
    File.ln_s!(ctx.root, ctx.root <> "-link")
    on_exit(fn -> File.rm(ctx.root <> "-link") end)
    assert {:error, :unsafe_path} = ScopedReader.read(ctx.scope, "one", root: ctx.root <> "-link")

    File.ln_s!(
      Path.join(ctx.root, "project/project-a"),
      Path.join(ctx.root, "project/project-link")
    )

    assert {:error, :unsafe_path} =
             ScopedReader.read(%{ctx.scope | project_id: "project-link"}, "one")

    File.ln_s!(path, Path.join(ctx.root, "project/project-a/link.md"))
    assert {:error, :unsafe_path} = ScopedReader.read(ctx.scope, "link")
    File.rm!(Path.join(ctx.root, "project/project-a/link.md"))
    File.ln!(path, Path.join(ctx.root, "project/project-a/hard.md"))
    assert {:error, :unsafe_path} = ScopedReader.read(ctx.scope, "one")
  end

  test "rejects forged ownership, duplicate YAML identity, malformed YAML and oversized files",
       ctx do
    store("one", "project-a", "owned")
    path = Path.join(ctx.root, "project/project-a/one.md")
    original = File.read!(path)

    for bad <- [
          String.replace(original, "scope_id: project-a", "scope_id: project-b"),
          String.replace(original, "id: one", "id: one\nid: other"),
          "---\nid: [unterminated\n---\nsecret",
          String.duplicate("x", 65_537)
        ] do
      File.write!(path, bad)
      assert {:error, reason} = ScopedReader.read(ctx.scope, "one")
      assert reason in [:ownership_mismatch, :malformed_record, :file_limit]
    end
  end

  test "enforces scan limit before reading candidates", ctx do
    dir = Path.join(ctx.root, "project/project-a")
    File.mkdir_p!(dir)
    for n <- 1..129, do: File.write!(Path.join(dir, "#{n}.md"), "malformed")
    assert {:error, :scan_limit} = ScopedReader.search(ctx.scope, "a")
  end

  test "deadline is explicit and combined output cannot exceed its fixed budget", ctx do
    for n <- 1..20, do: store("record-#{n}", "project-a", String.duplicate("match ", 2_000))
    assert {:error, :output_limit} = ScopedReader.search(ctx.scope, "match", limit: 20)

    assert {:error, :timeout} =
             ScopedReader.search(ctx.scope, "match",
               deadline: System.monotonic_time(:millisecond) - 1
             )

    assert {:error, :timeout} =
             ScopedReader.search(ctx.scope, "match",
               deadline: System.monotonic_time(:millisecond) + 1
             )
  end

  test "archives are excluded and oversized summaries are explicitly truncated", ctx do
    store("one", "project-a", String.duplicate("long ", 2_000))

    assert {:ok, %{record: %{truncated: true, summary: summary}}} =
             ScopedReader.read(ctx.scope, "one")

    assert byte_size(summary) <= 8_192
    assert :ok = FileAdapter.archive("one")
    assert {:error, :not_found} = ScopedReader.read(ctx.scope, "one")
    assert {:ok, %{results: []}} = ScopedReader.search(ctx.scope, "long")
  end

  test "searches full bounded summaries and strips one filename suffix", ctx do
    store("one.md", "project-a", String.duplicate("prefix ", 1_300) <> "suffix-keyword")

    assert {:ok, %{results: [%{memory_id: "one.md", truncated: true} = record]}} =
             ScopedReader.search(ctx.scope, "suffix-keyword")

    refute record.summary =~ "suffix-keyword"
    assert {:ok, %{record: ^record}} = ScopedReader.read(ctx.scope, "one.md")
  end

  test "archive markers must be null, absent, empty or valid ISO8601 timestamps", ctx do
    store("one", "project-a", "owned")
    path = Path.join(ctx.root, "project/project-a/one.md")
    original = File.read!(path)

    for marker <- ["false", "[]", "not-a-date", "2026-99-99T00:00:00Z"] do
      File.write!(path, String.replace_prefix(original, "---\n", "---\narchived_at: #{marker}\n"))
      assert {:error, :malformed_record} = ScopedReader.read(ctx.scope, "one")
      assert {:error, :malformed_record} = ScopedReader.search(ctx.scope, "owned")
    end

    for marker <- ["null", "\"\""] do
      File.write!(path, String.replace_prefix(original, "---\n", "---\narchived_at: #{marker}\n"))
      assert {:ok, %{record: %{memory_id: "one"}}} = ScopedReader.read(ctx.scope, "one")
      assert {:ok, %{results: [%{memory_id: "one"}]}} = ScopedReader.search(ctx.scope, "owned")
    end

    File.write!(path, original)
    assert {:ok, %{record: %{memory_id: "one"}}} = ScopedReader.read(ctx.scope, "one")
    assert :ok = FileAdapter.archive("one")
    assert {:error, :not_found} = ScopedReader.read(ctx.scope, "one")
    assert {:ok, %{results: []}} = ScopedReader.search(ctx.scope, "owned")
  end

  test "owner death terminates even a suspended filesystem worker", ctx do
    for n <- 1..128, do: store("record-#{n}", "project-a", String.duplicate("data ", 10_000))
    caller = spawn(fn -> receive do: (:go -> ScopedReader.search(ctx.scope, "data")) end)
    :erlang.trace_pattern({File, :open, 2}, true, [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.exit(caller, :kill)
    end)

    send(caller, :go)
    assert_receive {:trace, reader, :call, {File, :open, _}}, 1_000
    :erlang.suspend_process(reader)
    on_exit(fn -> Process.exit(reader, :kill) end)
    monitor = Process.monitor(reader)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 500
  end

  test "only absent tags default to an empty list; present tags must be string lists", ctx do
    store("one", "project-a", "owned")
    path = Path.join(ctx.root, "project/project-a/one.md")
    original = File.read!(path)

    for tags <- [
          "false",
          "true",
          "null",
          "42",
          "{}",
          "{private: secret}",
          "storage",
          "[storage, 42]",
          "[false]"
        ] do
      File.write!(path, String.replace(original, "tags: [storage]", "tags: #{tags}"))
      assert {:error, :malformed_record} = ScopedReader.read(ctx.scope, "one")
      assert {:error, :malformed_record} = ScopedReader.search(ctx.scope, "owned")
    end

    File.write!(path, String.replace(original, "tags: [storage]\n", ""))
    assert {:ok, %{record: %{tags: []}}} = ScopedReader.read(ctx.scope, "one")
    assert {:ok, %{results: [%{tags: []}]}} = ScopedReader.search(ctx.scope, "owned")
    File.write!(path, original)
    assert {:ok, %{record: %{tags: ["storage"]}}} = ScopedReader.read(ctx.scope, "one")
  end

  defp store(id, project, summary) do
    assert {:ok, _} =
             FileAdapter.store(%{
               id: id,
               scope: "project",
               scope_id: project,
               title: "Architecture",
               summary: summary,
               tags: ["storage"],
               detail: %{secret: "private"}
             })
  end

  defp snapshot(root) do
    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Map.new(fn path ->
      stat = File.stat!(path, time: :posix)
      {path, {File.read!(path), stat.mtime, stat.ctime, stat.size}}
    end)
  end
end
