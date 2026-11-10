defmodule Synapsis.SkillWorkshop.ContractFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.SkillWorkshop.Contract

  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @identity_advisory "Advisory (not blocking): description opens with \"This skill\"; open with the situation that triggers it. Fix with action=patch."
  @narrative_advisory "Advisory (not blocking): found an update note or date; fold the lesson into the step it changes. Fix with action=patch."

  # Independently frozen successful source expectations. No scanner, permission,
  # failure, output-budget or real-provider qualification belongs to this file.
  test "frontmatter returns source strings for ordinary scalar and structured metadata" do
    content =
      Enum.join(
        [
          "---",
          "name: deploy-guide",
          "description: Deploy a reviewed release.",
          "enabled: true",
          "retries: 3",
          "mode: yes",
          "tags:",
          "  - alpha",
          "  - beta",
          "metadata:",
          "  openclaw:",
          "    events:",
          "      - command:new",
          "display: {\"emoji\": \"disk\", \"label\": \"café\"} # display metadata",
          "flow: {a: 1,",
          "  b: 2}",
          "---",
          "Ordinary Markdown."
        ],
        "\n"
      )

    assert run(%{"operation" => "frontmatter", "content" => content}) == %{
             "name" => "deploy-guide",
             "description" => "Deploy a reviewed release.",
             "enabled" => "true",
             "retries" => "3",
             "mode" => "yes",
             "tags" => "[\"alpha\",\"beta\"]",
             "metadata" => "{\"openclaw\":{\"events\":[\"command:new\"]}}",
             "display" => "{\"emoji\": \"disk\", \"label\": \"café\"}",
             "flow" => "{\"a\":1,\"b\":2}"
           }
  end

  test "all three authored freeform fields recover without flattening structured siblings" do
    content =
      Enum.join(
        [
          "---",
          "name: deploy-guide",
          "description: Release: inspect the reviewed build.",
          "read_when: signals: user announcing a conversion task",
          "summary: handles formats: pdf and docx",
          "metadata:",
          "  openclaw:",
          "    emoji: beaker",
          "---",
          "Record the result."
        ],
        "\n"
      )

    assert run(%{"operation" => "frontmatter", "content" => content}) == %{
             "name" => "deploy-guide",
             "description" => "Release: inspect the reviewed build.",
             "read_when" => "signals: user announcing a conversion task",
             "summary" => "handles formats: pdf and docx",
             "metadata" => "{\"openclaw\":{\"emoji\":\"beaker\"}}"
           }
  end

  test "BOM and ordinary line-ending conventions preserve folded block metadata" do
    lines = [
      "---  ",
      "name: deploy-guide",
      "description: >-",
      "  Deploy a reviewed release",
      "  and record the result.",
      "---\t",
      "Body."
    ]

    for separator <- ["\r\n", "\r"] do
      content = "\uFEFF" <> Enum.join(lines, separator)

      assert run(%{"operation" => "frontmatter", "content" => content}) == %{
               "name" => "deploy-guide",
               "description" => "Deploy a reviewed release and record the result."
             }
    end
  end

  test "ordinary scalar and structured aliases resolve to source metadata strings" do
    content =
      Enum.join(
        [
          "---",
          "name: deploy-guide",
          "title: &trigger Deploy a reviewed release.",
          "description: *trigger",
          "shared: &release",
          "  steps:",
          "    - inspect",
          "    - record",
          "metadata: *release",
          "---",
          "Inspect the release."
        ],
        "\n"
      )

    assert run(%{"operation" => "frontmatter", "content" => content}) == %{
             "name" => "deploy-guide",
             "title" => "Deploy a reviewed release.",
             "description" => "Deploy a reviewed release.",
             "shared" => "{\"steps\":[\"inspect\",\"record\"]}",
             "metadata" => "{\"steps\":[\"inspect\",\"record\"]}"
           }
  end

  test "ordinary Markdown and support analysis preserve exact input bytes" do
    content = skill("Deploy a reviewed release.")

    request = %{
      "operation" => "analyze",
      "name" => "deploy-guide",
      "filePath" => "SKILL.md",
      "content" => content
    }

    assert run(request) == %{
             "frontmatter" => %{
               "name" => "deploy-guide",
               "description" => "Deploy a reviewed release."
             },
             "description" => "Deploy a reviewed release.",
             "advisories" => []
           }

    assert request["content"] ==
             "---\nname: deploy-guide\ndescription: Deploy a reviewed release.\n---\n\n1. Inspect the release.\n2. Record the result.\n"

    support = "{\"release\": \"<version>\", \"note\": \"café 雪 😀\"}\r\n$& $1 $$\n"

    for file_path <- ["examples/release.json", "templates/check.txt"] do
      request = %{
        "operation" => "analyze",
        "name" => "deploy-guide",
        "filePath" => file_path,
        "content" => support
      }

      assert run(request) == %{"advisories" => []}
      assert request["content"] == support
    end
  end

  test "successful analysis returns the first three newly introduced authoring rules" do
    content =
      skill(
        "This skill is powerful.",
        "- Never duplicate a release step.\n- Don't repeat the inventory.\n1. Do not repeat the report.\nUPDATE: Record the release result."
      )

    assert run(%{
             "operation" => "analyze",
             "name" => "deploy-guide",
             "filePath" => "SKILL.md",
             "content" => content
           }) == %{
             "frontmatter" => %{
               "name" => "deploy-guide",
               "description" => "This skill is powerful."
             },
             "description" => "This skill is powerful.",
             "advisories" => [
               @identity_advisory,
               "Advisory (not blocking): cut no-op emphasis (powerful); plain steps carry the same weight. Fix with action=patch.",
               "Advisory (not blocking): 3 lines start with Never/Don't; state the behavior to produce instead. Fix with action=patch."
             ]
           }
  end

  test "standing advice is suppressed by rule and quoted code stays outside prose advice" do
    before = skill("Deploy the reviewed release.", "1. Make sure to collect the result.")

    after_content =
      skill(
        "This skill records releases.",
        "1. IMPORTANT: Make sure to record the result.\nUPDATE: Fold the new step into the procedure."
      )

    assert run(%{"operation" => "advisories", "before" => before, "after" => after_content}) ==
             [@identity_advisory, @narrative_advisory]

    assert run(%{
             "operation" => "analyze",
             "name" => "deploy-guide",
             "filePath" => "SKILL.md",
             "content" => after_content,
             "before" => before,
             "maxSkillBytes" => 8192
           }) == %{
             "frontmatter" => %{
               "name" => "deploy-guide",
               "description" => "This skill records releases."
             },
             "description" => "This skill records releases.",
             "advisories" => [@identity_advisory, @narrative_advisory]
           }

    quoted =
      skill(
        "Deploy the reviewed release.",
        "1. Run `IMPORTANT robust`.\n```text\nUPDATE: robust\nNever duplicate.\nDon't repeat.\nDo not copy.\n```\n2. Record the result."
      )

    assert run(%{"operation" => "advisories", "before" => "", "after" => quoted}) == []
  end

  test "fresh ordinary callers each retire their own Node invocation before returning" do
    request = %{"operation" => "frontmatter", "content" => skill("Deploy a reviewed release.")}
    owner = self()

    receipts =
      for _ <- 1..2 do
        {caller, monitor} =
          spawn_monitor(fn ->
            result = Contract.run(request, deadline())
            send(owner, {:ordinary_workshop_contract, self(), result})
          end)

        assert_receive {:ordinary_workshop_contract, ^caller, {:ok, result, receipt}}, 6_000

        assert result == %{
                 "name" => "deploy-guide",
                 "description" => "Deploy a reviewed release."
               }

        assert_receipt(receipt)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
        refute Process.alive?(caller)
        receipt
      end

    assert Enum.uniq(Enum.map(receipts, & &1.os_pid)) == Enum.map(receipts, & &1.os_pid)
  end

  defp skill(description, body \\ "1. Inspect the release.\n2. Record the result.") do
    "---\nname: deploy-guide\ndescription: #{description}\n---\n\n#{body}\n"
  end

  defp run(request) do
    assert {:ok, result, receipt} = Contract.run(request, deadline())
    assert_receipt(receipt)
    result
  end

  defp assert_receipt(receipt) do
    assert %{
             reference_commit: @reference,
             exit_status: 0,
             os_pid: os_pid,
             closed: true,
             runtime: runtime
           } = receipt

    assert is_integer(os_pid) and os_pid > 0
    assert Map.keys(runtime) |> Enum.sort() == ~w(arch cldr icu node platform unicode v8)
    assert Enum.all?(Map.values(runtime), &(is_binary(&1) and byte_size(&1) > 0))
    assert Regex.match?(~r/^\d+\.\d+\.\d+$/, runtime["node"])
    refute File.exists?("/proc/#{os_pid}")
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
