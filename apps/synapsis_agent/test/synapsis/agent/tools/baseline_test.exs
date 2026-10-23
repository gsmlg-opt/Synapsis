defmodule Synapsis.Agent.Tools.BaselineTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../../../..", __DIR__)
  @baseline Path.join(
              @root,
              "docs/superpowers/specs/2026-10-23-openclaw-tool-alignment-baseline.json"
            )
  @mapping Path.expand("../../../fixtures/openclaw/488631c/capability-map.json", __DIR__)
  @native Path.expand("../../../fixtures/backplane/1.10.31/contracts.json", __DIR__)
  @reference Path.expand("../../../fixtures/openclaw/488631c/capture.json", __DIR__)

  test "every pinned reference has a distinct capability assessment under Backplane authority" do
    baseline = read_json(@baseline)
    mapping = read_json(@mapping)

    assert mapping["referenceCommit"] == baseline["sha"]
    assert mapping["runtimeContractAuthority"] == "backplane_agent_runtime"
    assert mapping["runtimeVersion"] == "1.10.31"

    names = Enum.map(mapping["coverage"], & &1["referenceTool"])
    assert Enum.sort(names) == baseline["union"]
    assert names == Enum.uniq(names)

    phases = Map.new(baseline["coverage"], &{&1["name"], &1["phase"]})

    for entry <- mapping["coverage"] do
      assert entry["phase"] == phases[entry["referenceTool"]]
      assert entry["disposition"] in ["native-reuse", "host-extension", "host-adapted", "gap"]
      assert [_ | _] = entry["behaviorDifferences"]

      assert %{"implementation" => "planned", "localContractVerified" => false} =
               entry["evidence"]
    end
  end

  test "existing native capabilities retain their admitted names instead of OpenClaw aliases" do
    coverage = Map.new(read_json(@mapping)["coverage"], &{&1["referenceTool"], &1})

    for {reference, native} <- [
          {"exec", "exec_command"},
          {"process", "write_stdin"},
          {"apply_patch", "apply_patch"},
          {"view_image", "view_image"},
          {"sessions_spawn", "spawn_agent"},
          {"agents_wait", "wait_agent"}
        ] do
      assert native in coverage[reference]["targetTools"]
      assert coverage[reference]["disposition"] == "native-reuse"
    end

    refute "exec" in coverage["exec"]["targetTools"]
    refute "sessions_spawn" in coverage["sessions_spawn"]["targetTools"]
  end

  test "persisted sessions and secret custody are not claimed as native child or approval tools" do
    coverage = Map.new(read_json(@mapping)["coverage"], &{&1["referenceTool"], &1})

    assert coverage["sessions_send"]["disposition"] == "host-extension"
    assert coverage["sessions"]["disposition"] == "host-extension"
    assert coverage["secrets"]["disposition"] == "host-extension"
    refute "request_permissions" in coverage["secrets"]["targetTools"]
  end

  test "test-only recovery references cannot become production capability targets" do
    coverage = read_json(@mapping)["coverage"]

    assert coverage
           |> Enum.filter(& &1["testOnly"])
           |> Enum.map(& &1["referenceTool"])
           |> Enum.sort() == ["qa_restart_unsafe_probe", "qa_restart_wait"]

    for entry <- Enum.filter(coverage, & &1["testOnly"]) do
      assert entry["productionExposure"] == "never"
      assert entry["targetTools"] == []
    end
  end

  test "native reuse targets exist in their pinned native profile families" do
    profiles = read_json(@native)["profiles"]

    for entry <- read_json(@mapping)["coverage"], entry["disposition"] == "native-reuse" do
      available =
        Enum.flat_map(entry["nativeFamilies"], fn family ->
          Enum.map(profiles[family]["descriptors"], & &1["tool_name"])
        end)

      assert [_ | _] = entry["targetTools"]
      assert entry["targetTools"] -- available == []
    end
  end

  test "runtime controls and recognized-only names retain separate evidence states" do
    baseline = read_json(@baseline)
    mapping = read_json(@mapping)
    controls = Map.new(mapping["controls"], &{&1["referenceControl"], &1})

    assert Enum.sort(Map.keys(controls)) ==
             Enum.sort(Enum.map(baseline["runtimeControls"], & &1["name"]))

    assert mapping["recognizedOnly"] == baseline["runtimeRecognizedOnly"]
    assert controls["structured_output"]["disposition"] == "gap"
    assert controls["structured_output"]["nativeFamilies"] == []

    for name <- ["tool_describe", "dispatch_action"] do
      refute controls[name]["disposition"] == "native-reuse"
    end
  end

  test "captured reference schemas link to source evidence without claiming implemented actions" do
    recipes = Map.new(read_json(@reference)["recipes"], &{&1["id"], &1})
    coverage = Map.new(read_json(@mapping)["coverage"], &{&1["referenceTool"], &1})

    for name <- ["canvas", "llm-task", "voice_call"] do
      assert [_ | _] = coverage[name]["referenceSchemas"]

      for evidence <- coverage[name]["referenceSchemas"] do
        recipe = recipes[evidence["recipe"]]
        assert recipe["status"] == "captured"
        assert recipe["referenceTool"] == name
        assert recipe["schema"]["schemaSha256"] == evidence["schemaSha256"]
        assert recipe["sourceSha256"] == evidence["sourceSha256"]
        assert recipe["evidence"] == evidence["evidence"]
        assert recipe["eligibility"]["status"] == "unresolved"
      end

      assert coverage[name]["evidence"]["implementation"] == "planned"
      refute coverage[name]["evidence"]["localContractVerified"]
    end
  end

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()
end
