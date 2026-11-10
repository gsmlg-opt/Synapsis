defmodule Synapsis.Filesystem.PrepareTargetFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.Local

  @moduletag :tmp_dir

  # Literal ordinary oracles were frozen in source-expectations.md before this
  # file existed, from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b:
  # path-policy.ts, sandbox-paths.ts, sessions/tools/path-utils.ts and read.ts.
  # Source/display spelling and the selected root-relative path are independent.
  setup %{tmp_dir: root} do
    cwd = Path.join(root, "project")
    home = Path.join(root, "home")
    other = Path.join(root, "other-workspace")
    for directory <- [cwd, home, other], do: File.mkdir_p!(directory)

    environment = %{cwd: cwd, os_home: home, platform: :linux, workspace_root: other}
    %{root: root, cwd: cwd, environment: environment}
  end

  test "captures cwd and OS home while preserving literal references URL bytes and spaces", ctx do
    fixtures(ctx.root, [
      {"project/notes.txt", "ordinary\n"},
      {"project/@notes.txt", "literal at\n"},
      {"project/reference.txt", "reference\n"},
      {"project/space name-é.txt", "URL bytes\n"},
      {"project/ notes.txt ", "spaced bytes\n"},
      {"home/home.txt", "captured home\n"},
      {"other-workspace/notes.txt", "other workspace\n"}
    ])

    File.mkdir_p!(Path.join(ctx.cwd, "@literal"))
    absolute = Path.join(ctx.cwd, "notes.txt")
    localhost_url = "file://localhost" <> ctx.cwd <> "/space%20name-%C3%A9.txt?download=1#part"
    reference_url = "@file://" <> ctx.cwd <> "/space%20name-%C3%A9.txt"

    cases = [
      {"notes.txt", :read, "notes.txt", "project/notes.txt"},
      {absolute, :read, absolute, "project/notes.txt"},
      {"@" <> absolute, :read, "@" <> absolute, "project/notes.txt"},
      {"~/home.txt", :read, "~/home.txt", "home/home.txt"},
      {"@~/home.txt", :read, "@~/home.txt", "home/home.txt"},
      {"~", :ls, "~", "home"},
      {"@notes.txt", :read, "./@notes.txt", "project/@notes.txt"},
      {"@literal/new.txt", :write, "./@literal/new.txt", "project/@literal/new.txt"},
      {"@reference.txt", :read, "@reference.txt", "project/reference.txt"},
      {"@@notes.txt", :read, "@@notes.txt", "project/@notes.txt"},
      {localhost_url, :read, localhost_url, "project/space name-é.txt"},
      {reference_url, :read, reference_url, "project/space name-é.txt"},
      {" notes.txt ", :read, " notes.txt ", "project/ notes.txt "},
      {".", :ls, ".", "project"}
    ]

    {results, calls} =
      trace_payload_calls(fn ->
        for {input, operation, display, selected} <- cases do
          expected = target(ctx.root, display, selected, selected, "")
          deadline = System.monotonic_time(:millisecond) + 5_000

          assert {:ok, ^expected} =
                   Local.prepare_target(ctx.root, input, operation, ctx.environment,
                     deadline: deadline
                   )
        end
      end)

    assert length(results) == 14
    assert calls == []
    assert File.read!(Path.join(ctx.cwd, "@notes.txt")) == "literal at\n"
    assert File.read!(Path.join(ctx.root, "home/home.txt")) == "captured home\n"
  end

  test "sole successful basename variants preserve parents and exact source notes", ctx do
    fixtures(ctx.root, [
      {"project/unicode/space name.txt", "ASCII space\n"},
      {"project/unicode/Screenshot 1\u202FPM.txt", "screenshot\n"},
      {"project/unicode/Sam’s.txt", "curly quote\n"},
      {"project/unicode/Left's.txt", "straight quote\n"},
      {"project/unicode/café.txt", "NFC\n"},
      {"project/unicode/résumé.txt", "NFC résumé\n"},
      {"project/unicode/nai\u0308ve.txt", "NFD\n"}
    ])

    cases = [
      {:linux, "unicode/space\u00A0name.txt", "unicode/space name.txt",
       "[Resolved filename: space\u00A0name.txt -> space name.txt.]\n"},
      {:linux, "unicode/Screenshot 1 PM.txt", "unicode/Screenshot 1\u202FPM.txt",
       "[Resolved filename: Screenshot 1 PM.txt -> Screenshot 1\u202FPM.txt.]\n"},
      {:linux, "unicode/Sam's.txt", "unicode/Sam’s.txt",
       "[Resolved filename: Sam's.txt -> Sam’s.txt.]\n"},
      {:linux, "unicode/Left‘s.txt", "unicode/Left's.txt",
       "[Resolved filename: Left‘s.txt -> Left's.txt.]\n"},
      {:linux, "unicode/cafe\u0301.txt", "unicode/café.txt",
       "[Resolved filename: cafe\u0301.txt -> café.txt.]\n"},
      {:linux, "unicode/re\u0301sume\u0301.txt", "unicode/résumé.txt",
       "[Resolved filename: re\u0301sume\u0301.txt -> résumé.txt.]\n"},
      {:darwin, "unicode/re\u0301sume\u0301.txt", "unicode/résumé.txt",
       "[Resolved filename: re\u0301sume\u0301.txt -> résumé.txt.]\n"},
      {:linux, "unicode/naïve.txt", "unicode/nai\u0308ve.txt",
       "[Resolved filename: naïve.txt -> nai\u0308ve.txt.]\n"}
    ]

    {results, calls} =
      trace_payload_calls(fn ->
        for {platform, input, selected, prefix} <- cases do
          expected = target(ctx.root, input, "project/" <> input, "project/" <> selected, prefix)

          assert {:ok, ^expected} =
                   Local.prepare_target(
                     ctx.root,
                     input,
                     :read,
                     %{ctx.environment | platform: platform},
                     deadline: System.monotonic_time(:millisecond) + 5_000
                   )
        end
      end)

    assert length(results) == 8
    assert calls == []
    assert File.read!(Path.join(ctx.cwd, "unicode/Sam’s.txt")) == "curly quote\n"
  end

  test "exact names win and write edit and list preparation remain metadata only", ctx do
    fixtures(ctx.root, [
      {"project/Sam's.txt", "exact body\n"},
      {"project/Sam’s.txt", "variant body\n"}
    ])

    File.mkdir_p!(Path.join(ctx.cwd, "listing"))
    File.write!(Path.join(ctx.cwd, "listing/entry.txt"), "listed body\n")

    cases = [
      {:read, "Sam's.txt", "project/Sam's.txt"},
      {:write, "Sam's.txt", "project/Sam's.txt"},
      {:edit, "Sam's.txt", "project/Sam's.txt"},
      {:ls, "listing", "project/listing"}
    ]

    {results, calls} =
      trace_payload_calls(fn ->
        for {operation, input, selected} <- cases do
          expected = target(ctx.root, input, selected, selected, "")

          assert {:ok, ^expected} =
                   Local.prepare_target(ctx.root, input, operation, ctx.environment,
                     deadline: System.monotonic_time(:millisecond) + 5_000
                   )
        end
      end)

    assert length(results) == 4
    assert calls == []
    assert File.read!(Path.join(ctx.cwd, "Sam's.txt")) == "exact body\n"
    assert File.read!(Path.join(ctx.cwd, "Sam’s.txt")) == "variant body\n"
    assert File.read!(Path.join(ctx.cwd, "listing/entry.txt")) == "listed body\n"
  end

  defp target(root, source, requested, selected, prefix) do
    %{
      source_path: source,
      requested_absolute: Path.join(root, requested),
      absolute_path: Path.join(root, selected),
      relative_path: selected,
      source_prefix: prefix
    }
  end

  defp fixtures(root, files) do
    for {relative, bytes} <- files do
      absolute = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, bytes)
    end
  end

  # Trace only the invocation and its ordinary children. Fixture reads/writes
  # happen outside this scope. No replacement filesystem or helper is installed.
  defp trace_payload_calls(callback) do
    patterns = [
      {File, :read, 1},
      {File, :read!, 1},
      {File, :open, 2},
      {File, :open, 3},
      {File, :write, 2},
      {File, :write, 3},
      {File, :write!, 2},
      {File, :write!, 3},
      {File, :ls, 1},
      {File, :ls!, 1},
      {:file, :read_file, 1},
      {:file, :open, 2},
      {:file, :write_file, 2},
      {:file, :write_file, 3},
      {:file, :list_dir, 1},
      {Local, :read_binary, :_},
      {Local, :directory_snapshot, :_},
      {Synapsis.Filesystem.ReadContent, :_, :_},
      {Synapsis.Filesystem.Planner.PortSession, :_, :_}
    ]

    for module <- [
          File,
          Local,
          Synapsis.Filesystem.ReadContent,
          Synapsis.Filesystem.Planner.PortSession
        ],
        do: Code.ensure_loaded!(module)

    for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local])
    task = Task.async(fn -> receive do: (:prepare_now -> callback.()) end)
    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :prepare_now)

    try do
      actual = Task.await(task, 20_000)
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      {actual, payload_calls([])}
    after
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
    end
  end

  defp payload_calls(calls) do
    receive do
      {:trace, _pid, :call, call} -> payload_calls([call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
