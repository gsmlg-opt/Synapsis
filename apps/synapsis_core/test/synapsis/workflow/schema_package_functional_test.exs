defmodule Synapsis.Workflow.SchemaPackageFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Schema, Segment}
  alias Synapsis.Workflow.Schema.PortSession

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @repository Path.expand("../../../../..", __DIR__)
  @package Path.join(@repository, "apps/synapsis_core/priv/workflow_schema")
  @fixture Path.expand("../../fixtures/workflow_segment_cases.json", __DIR__)
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!()
  @fixture_hash "ae6af2db1818c9abc84ad2a8bc93756824de64c68136b4357bebdb626ed61883"
  @lock_hash "a58b322b0b7a959160436b0eddf59624cc3eacb7e1e667bd3f1ca0a8c7f83167"
  @hosts %{
    "schema-stdio.mjs" => "0cb42b16806adfb4655c95037ddecec582f742a94df4f8913c9c0c6480084835",
    "schema-worker.mjs" => "d4cd27d5441ebc89b94a10b250dab42321bac3ed0c20b9c4b71daaca3a0fa9dc",
    "schema.mjs" => "7c4ab9c824dc2ad28dda4286a7e00c5be22c4528be891d9bf89f8ccb4be79605",
    "template.mjs" => "06452b2e4bfc32b0ede0bc6222a7e1b5774b58a43f638e29a57fe968a73e9b3a"
  }
  @packages %{
    "node_modules/ajv" =>
      {"ajv", "8.20.0", 513, 1_274_698, "LICENSE",
       "a05350a88e318e4f5f2c2a1ff1e2e88daa4dd38e6e78b71cccae422bdc762cc3"},
    "node_modules/ajv/node_modules/fast-uri" =>
      {"fast-uri", "3.1.9", 47, 241_202, "LICENSE",
       "b010b0dfdfdb23d7396e03b82cd4621fc9bb8f95d6b0aea70b9c24e12074c786"},
    "node_modules/fast-uri" =>
      {"fast-uri", "4.2.2", 53, 312_483, "LICENSE",
       "b010b0dfdfdb23d7396e03b82cd4621fc9bb8f95d6b0aea70b9c24e12074c786"},
    "node_modules/fast-deep-equal" =>
      {"fast-deep-equal", "3.1.3", 11, 12_966, "LICENSE",
       "7bf9b2de73a6b356761c948d0e9eeb4be6c1270bd04c79cd489c1e400ffdfc1a"},
    "node_modules/json-schema-traverse" =>
      {"json-schema-traverse", "1.0.0", 12, 22_220, "LICENSE",
       "7bf9b2de73a6b356761c948d0e9eeb4be6c1270bd04c79cd489c1e400ffdfc1a"},
    "node_modules/require-from-string" =>
      {"require-from-string", "2.0.2", 4, 3_422, "license",
       "6ee0feb1f6ef996ff5a68600f8cf98909cf412d39ef3cdceaefd87d636fa1b7f"}
  }

  # Frozen before the builder, dependency manifest or generated tree existed.
  # Behavioral literals remain the separately protected batch228 fixture.
  setup do
    root =
      Path.join(System.tmp_dir!(), "synapsis-relocated-workflow-schema-" <> Ecto.UUID.generate())

    refute String.starts_with?(Path.expand(root), @repository <> "/")
    assembled = Path.join(root, "assembled helper")
    relocated = Path.join(root, "relocated helper")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, _} = File.cp_r(@package, assembled)
    assert :ok = File.rename(assembled, relocated)
    %{helper_root: relocated}
  end

  test "relocated complete helper preserves original modules, locked packages, licenses and provenance",
       ctx do
    assert sha(File.read!(@fixture)) == @fixture_hash
    assert sha(File.read!(Path.join(@repository, "package-lock.json"))) == @lock_hash
    source_files = files(@package)
    relocated_files = files(ctx.helper_root)
    assert length(relocated_files) == 599
    assert relocated_files == source_files

    for path <- relocated_files do
      assert File.read!(Path.join(ctx.helper_root, path)) == File.read!(Path.join(@package, path))
      refute Path.basename(path) == ".npm-ex-cache-complete"
    end

    manifest_path = Path.join(@repository, "packages/tool-host/src/workflow/dependencies.json")
    manifest_bytes = File.read!(manifest_path)
    assert File.read!(Path.join(ctx.helper_root, "pinned-dependencies.json")) == manifest_bytes
    manifest = Jason.decode!(manifest_bytes)
    assert manifest["version"] == 1
    assert manifest["sourceLock"] == "package-lock.json"
    assert manifest["sourceLockSha256"] == @lock_hash

    assert manifest["roots"] == %{
             "ajv" => "node_modules/ajv",
             "fast-uri" => "node_modules/fast-uri"
           }

    assert Enum.sort(Map.keys(manifest["packages"])) == Enum.sort(Map.keys(@packages))

    assert manifest["packages"]["node_modules/ajv"]["dependencies"] == %{
             "fast-deep-equal" => "node_modules/fast-deep-equal",
             "fast-uri" => "node_modules/ajv/node_modules/fast-uri",
             "json-schema-traverse" => "node_modules/json-schema-traverse",
             "require-from-string" => "node_modules/require-from-string"
           }

    lock = @repository |> Path.join("package-lock.json") |> File.read!() |> Jason.decode!()
    provenance_bytes = File.read!(Path.join(ctx.helper_root, "provenance.json"))
    provenance = Jason.decode!(provenance_bytes)
    refute provenance_bytes =~ @repository
    refute provenance_bytes =~ ctx.helper_root
    assert provenance["version"] == 1
    assert provenance["transformation"] == %{"version" => 1, "mode" => "byte-copy"}
    assert provenance["sourceLock"] == %{"path" => "package-lock.json", "sha256" => @lock_hash}
    assert length(provenance["host"]) == 4
    assert length(provenance["dependencies"]) == 6

    for {path, expected_hash} <- @hosts do
      source = Path.join(@repository, "packages/tool-host/src/workflow/" <> path)
      assert sha(File.read!(source)) == expected_hash
      assert File.read!(Path.join(ctx.helper_root, path)) == File.read!(source)

      assert %{
               "path" => "packages/tool-host/src/workflow/" <> path,
               "generated" => path,
               "sourceSha256" => expected_hash,
               "generatedSha256" => expected_hash
             } in provenance["host"]
    end

    for {path, {name, version, count, bytes, license, license_hash}} <- @packages do
      pin = manifest["packages"][path]
      assert pin["name"] == name
      assert pin["version"] == version
      assert pin["lock"] == lock["packages"][path]
      assert map_size(pin["files"]) == count
      assert pin["bytes"] == bytes
      assert pin["licenses"][license] == license_hash
      assert Map.put(pin, "path", path) in provenance["dependencies"]

      installed =
        @repository
        |> Path.join(path)
        |> Path.join("package.json")
        |> File.read!()
        |> Jason.decode!()

      packaged =
        ctx.helper_root
        |> Path.join(path)
        |> Path.join("package.json")
        |> File.read!()
        |> Jason.decode!()

      assert packaged == installed
      assert packaged["name"] == name and packaged["version"] == version
      assert sha(File.read!(Path.join([ctx.helper_root, path, license]))) == license_hash

      for {relative, expected_hash} <- pin["files"] do
        packaged_bytes = File.read!(Path.join([ctx.helper_root, path, relative]))
        assert sha(packaged_bytes) == expected_hash
        assert packaged_bytes == File.read!(Path.join([@repository, path, relative]))
      end
    end

    artifact_paths = Enum.map(provenance["artifacts"], & &1["path"])
    assert artifact_paths == Enum.sort(relocated_files -- ["provenance.json"])

    for artifact <- provenance["artifacts"] do
      assert sha(File.read!(Path.join(ctx.helper_root, artifact["path"]))) == artifact["sha256"]
    end
  end

  test "isolated packaged Ajv drives both checkpoint modes, fresh resume and ordinary completion",
       ctx do
    assert sha(File.read!(@fixture)) == @fixture_hash
    assert Enum.map(@cases["cases"], & &1["name"]) == ["same_stage", "next_stage", "complete"]

    for item <- @cases["cases"] do
      assert {:ok, initial} = Segment.new(item["pipeline"])

      {{kind, boundary, requests}, first_pid} =
        with_helper(ctx.helper_root, fn helper -> drive(initial, helper) end)

      assert requests == item["before_requests"]
      assert boundary["source"] == %{"kind" => "inline", "pipeline" => item["pipeline"]}
      assert boundary["journal"] == %{"kind" => "workflow", "version" => 1, "effects" => []}
      restored = boundary |> Jason.encode!() |> Jason.decode!()
      assert restored === boundary

      if kind == :complete do
        assert item["name"] == "complete"
        assert {:ok, envelope} = Segment.envelope(restored, "unused")

        assert envelope == %{
                 "ok" => true,
                 "status" => "ok",
                 "output" => [],
                 "requiresApproval" => nil
               }
      else
        assert kind == :checkpoint
        assert restored["machine"]["checkpoint"]["mode"] == item["mode"]
        assert restored["machine"]["checkpoint"]["stage_index"] == item["stage_index"]
        assert {:ok, envelope} = Segment.envelope(restored, "literal-relocated-token")

        assert envelope == %{
                 "ok" => true,
                 "status" => "needs_input",
                 "output" => [],
                 "requiresApproval" => nil,
                 "requiresInput" => %{
                   "type" => "input_request",
                   "prompt" => "Choose tag",
                   "responseSchema" => @cases["schema"],
                   "resumeToken" => "literal-relocated-token"
                 }
               }

        assert {:ok, resuming} = Segment.resume(restored, item["response_json"])
        assert Enum.map(resuming["machine"]["program"], & &1["name"]) == item["resumed_program"]

        {{:complete, completed, requests}, second_pid} =
          with_helper(ctx.helper_root, fn helper -> drive(resuming, helper) end)

        assert is_integer(first_pid) and is_integer(second_pid) and first_pid != second_pid
        assert requests == item["claim_requests"] ++ item["after_requests"]
        assert {:ok, envelope} = Segment.envelope(completed, "unused")

        assert envelope == %{
                 "ok" => true,
                 "status" => "ok",
                 "output" => item["output"],
                 "requiresApproval" => nil
               }
      end
    end
  end

  defp with_helper(root, function) do
    helper =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path: Path.join(root, "schema-stdio.mjs")},
        id: make_ref()
      )

    assert %{phase: :dormant, os_pid: nil} = PortSession.status(helper)

    try do
      result = function.(helper)

      assert {:ok, %{cleanup_confirmed: true, os_pid: os_pid} = status} =
               PortSession.close(helper)

      if os_pid do
        assert status.exit_status == 0
        refute File.exists?("/proc/#{os_pid}")
      end

      {result, os_pid}
    after
      if Process.alive?(helper), do: PortSession.close(helper)
    end
  end

  defp drive(snapshot, helper, requests \\ []) do
    case Segment.advance(snapshot) do
      {:continue, next} ->
        drive(next, helper, requests)

      {:request, request, pending} ->
        assert {:continue, machine} = Schema.advance_pending(helper, pending["machine"], 15_000)

        drive(
          Map.put(pending, "machine", machine),
          helper,
          requests ++ [[request["kind"], request["boundary"]]]
        )

      {:checkpoint, _, next} ->
        {:checkpoint, next, requests}

      {:complete, _, next} ->
        {:complete, next, requests}

      other ->
        flunk("unexpected ordinary relocated transition: #{inspect(other)}")
    end
  end

  defp files(root, prefix \\ "") do
    for name <- File.ls!(Path.join(root, prefix)) |> Enum.sort(), reduce: [] do
      paths ->
        relative = Path.join(prefix, name)

        case File.lstat!(Path.join(root, relative)).type do
          :directory -> paths ++ files(root, relative)
          :regular -> paths ++ [relative]
          type -> flunk("package entry is not a copied regular file/directory: #{type}")
        end
    end
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
