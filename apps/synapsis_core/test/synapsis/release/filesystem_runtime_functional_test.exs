defmodule Synapsis.Release.FilesystemRuntimeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.Planner.PortSession

  @moduletag :tmp_dir
  @repository Path.expand("../../../../..", __DIR__)
  @fixture Path.join(
             @repository,
             "apps/synapsis_agent/test/fixtures/openclaw/488631c/edit-plans.json"
           )
  @fixture_sha256 "a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0"
  @node_sha256 "e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb"
  @license_sha256 "5888dbb9a1d2b18f2c3e6c5f6af1b39de658372b402a0577b002777f14c62ace"
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
  @ordinary_ids ~w(original-snapshot reversed-request unicode-utf16 identical-noop normalized-noop bom-crlf line-ending-style fuzzy-preserves-untouched write-create write-overwrite)

  setup_all do
    Code.require_file(Path.join(@repository, "rel/filesystem_runtime.exs"))
    source = System.fetch_env!("SYNAPSIS_FILESYSTEM_RUNTIME_ROOT")
    assert Path.type(source) == :absolute
    assert sha256(File.read!(Path.join(source, "bin/node"))) == @node_sha256
    assert sha256(File.read!(Path.join(source, "LICENSE"))) == @license_sha256

    bytes = File.read!(@fixture)
    assert sha256(bytes) == @fixture_sha256
    fixture = Jason.decode!(bytes)
    assert fixture["reference"]["commit"] == @reference_commit
    assert Enum.map(fixture["cases"], & &1["id"]) == @ordinary_ids

    on_exit(fn -> assert File.read!(@fixture) == bytes end)
    {:ok, source: source, fixture: fixture}
  end

  setup %{tmp_dir: root} do
    assembled = Path.join(root, "assembled release")

    release = %Mix.Release{
      name: :synapsis,
      version: "0.2.4",
      path: assembled,
      version_path: Path.join(assembled, "releases/0.2.4")
    }

    File.mkdir_p!(release.version_path)
    assert Synapsis.Release.FilesystemRuntime.bundle(release) == release

    template = Path.join(@repository, "rel/env.sh.eex")

    File.write!(
      Path.join(release.version_path, "env.sh"),
      EEx.eval_file(template, release: release)
    )

    relocated = Path.join(root, "relocated release")
    File.rename!(assembled, relocated)
    node = Path.join(relocated, "releases/0.2.4/filesystem-node/bin/node")
    {:ok, release_root: relocated, node: node}
  end

  test "versioned runtime and complete license survive relocation and actual release environment",
       ctx do
    assert File.read!(ctx.node) == File.read!(Path.join(ctx.source, "bin/node"))
    assert sha256(File.read!(ctx.node)) == @node_sha256
    license = Path.join(ctx.release_root, "releases/0.2.4/filesystem-node/LICENSE")
    assert File.read!(license) == File.read!(Path.join(ctx.source, "LICENSE"))
    assert sha256(File.read!(license)) == @license_sha256
    assert Bitwise.band(File.stat!(ctx.node).mode, 0o111) == 0o111

    expression =
      "JSON.stringify({node:process.versions.node,v8:process.versions.v8," <>
        "unicode:process.versions.unicode,icu:process.versions.icu," <>
        "cldr:process.versions.cldr,platform:process.platform,arch:process.arch," <>
        "execPath:process.execPath})"

    shell = System.find_executable("sh")
    assert is_binary(shell)

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: [
          "-c",
          ~S(. "$RELEASE_ROOT/releases/$RELEASE_VSN/env.sh"; exec "$SYNAPSIS_FILESYSTEM_NODE" -p "$1"),
          "filesystem-release",
          expression
        ],
        env: [
          {~c"RELEASE_ROOT", String.to_charlist(ctx.release_root)},
          {~c"RELEASE_VSN", ~c"0.2.4"},
          {~c"SYNAPSIS_FILESYSTEM_NODE", false}
        ]
      ])

    output = collect(port, [], System.monotonic_time(:millisecond) + 5_000)
    assert Jason.decode!(output) == Map.put(@runtime, "execPath", ctx.node)
    assert Port.info(port) == nil
  end

  test "relocated real runtime executes all ten fixed source plans and normally retires", ctx do
    for row <- ctx.fixture["cases"] do
      assert {:ok, broker} =
               PortSession.start_link(
                 owner_pid: self(),
                 caller_pid: self(),
                 node_executable: ctx.node,
                 helper_path:
                   Path.join(:code.priv_dir(:synapsis_core), "filesystem_planner/stdio.mjs")
               )

      assert %{phase: :dormant, os_pid: nil} = PortSession.status(broker)

      request = %{
        "protocol" => 1,
        "id" => "batch225:" <> row["id"],
        "operation" => if(row["kind"] == "edit", do: "edit", else: "write_diff"),
        "input" => row["input"]
      }

      expected = %{
        "protocol" => 1,
        "id" => request["id"],
        "result" => row["result"],
        "runtime" => @runtime,
        "referenceCommit" => @reference_commit,
        "diffVersion" => "9.0.0"
      }

      deadline = System.monotonic_time(:millisecond) + 5_000
      assert {:ok, actual} = PortSession.plan(broker, request, deadline)
      assert actual == expected, row["id"]

      status = PortSession.status(broker)

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
      monitor = Process.monitor(broker)
      assert {:ok, ^status} = PortSession.close(broker)
      assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1_000
      refute Process.alive?(broker)
    end
  end

  defp collect(port, chunks, deadline) do
    receive do
      {^port, {:data, bytes}} -> collect(port, [chunks, bytes], deadline)
      {^port, {:exit_status, 0}} -> IO.iodata_to_binary(chunks)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("ordinary relocated runtime did not complete")
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
