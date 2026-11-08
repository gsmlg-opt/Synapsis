defmodule Synapsis.Workflow.TemplatePortFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.Value

  @moduletag timeout: 120_000
  @repository Path.expand("../../../../..", __DIR__)
  @fixture Path.join(
             @repository,
             "packages/tool-host/test/fixtures/workflow-template-requests.json"
           )
  @external_resource @fixture
  @corpus @fixture |> File.read!() |> Jason.decode!()
  @source_helper Path.join(@repository, "packages/tool-host/src/workflow/schema-stdio.mjs")
  @package Path.join(@repository, "apps/synapsis_core/priv/workflow_schema")
  @operation_timeout 15_000

  # The literal corpus was frozen before these tests or production changes.
  # Source CASES supplied all 114 expected strings; the independent UTF16
  # fixture supplied all 23 passthrough strings. No formatter is an oracle.
  test "the frozen 137 requests retain independent source provenance and canonical expectations" do
    assert @corpus["version"] == 1
    assert @corpus["provenance"]["template_count"] == 114
    assert @corpus["provenance"]["utf16_count"] == 23
    assert @corpus["provenance"]["total_count"] == 137
    assert length(@corpus["cases"]) == 137
    assert @corpus["cases"] |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 137

    for kind <- ["template", "utf16"] do
      path = Path.join(@repository, @corpus["provenance"][kind <> "_source"])
      assert sha(File.read!(path)) == @corpus["provenance"][kind <> "_source_sha256"]
    end

    for item <- @corpus["cases"] do
      assert item["request"]["id"] == item["id"]
      assert item["request"]["kind"] == "render_template"
      raw = for unit <- item["expected_units"], into: <<>>, do: <<unit::unsigned-little-16>>
      assert Base.encode64(raw) == item["expected_utf16le"]
      assert Value.to_utf16le(item["expected"]) == raw

      assert WorkflowJSON.stringify(item["expected"], item["heap"]) ==
               {:ok, item["expected_json"]}
    end
  end

  test "source PortSession renders all 137 literals in one PID and preserves the actual Ajv cache" do
    with_session(@source_helper, &run_corpus/1)
  end

  test "relocated standalone package renders all 137 literals in one PID with canonical UTF16 transport" do
    root = Path.join(System.tmp_dir!(), "synapsis-template-port-" <> Ecto.UUID.generate())
    assembled = Path.join(root, "assembled helper")
    relocated = Path.join(root, "relocated helper")
    refute String.starts_with?(Path.expand(root), @repository <> "/")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, _} = File.cp_r(@package, assembled)
    assert :ok = File.rename(assembled, relocated)
    refute File.exists?(assembled)
    helper = Path.join(relocated, "schema-stdio.mjs")
    assert File.read!(helper) == File.read!(@source_helper)
    with_session(helper, &run_corpus/1)
  end

  defp run_corpus(session) do
    {request, heap} = string_schema("compile:before", "compile_schema")
    assert_result(session, request, heap, receipt("compile:before", "compiled", 1))
    assert %{phase: :idle, os_pid: os_pid, cache_entries: 1} = PortSession.status(session)
    assert is_integer(os_pid)
    assert File.exists?("/proc/#{os_pid}")

    {request, heap} =
      string_schema("validate:before", "validate_response", %{
        "type" => "string",
        "value" => "ordinary"
      })

    assert_result(session, request, heap, receipt("validate:before", "valid", 1))
    assert_session(session, os_pid, 1)

    returned =
      for item <- @corpus["cases"], into: %{} do
        result =
          assert_render(
            session,
            item["request"],
            item["heap"],
            item["expected"],
            item["expected_units"],
            item["expected_json"],
            1
          )

        assert Base.encode64(Value.to_utf16le(result["value"])) == item["expected_utf16le"]
        assert_session(session, os_pid, 1)
        {item["id"], result["value"]}
      end

    # This separate vector exercises the template root's new tag, in addition
    # to the frozen passthrough items. It does not change the 137-case corpus.
    request = %{
      "id" => "lone:template-root",
      "kind" => "render_template",
      "template" => %{"type" => "string", "utf16le" => "Pdh7AHsAdgB9AH0AAN4="},
      "item" => %{"type" => "reference", "id" => "1"}
    }

    heap = %{
      "version" => 1,
      "next_id" => 2,
      "nodes" => %{
        "1" => %{
          "type" => "object",
          "keys" => ["v"],
          "fields" => %{"v" => %{"type" => "string", "value" => "雪"}}
        }
      }
    }

    assert_render(
      session,
      request,
      heap,
      %{"type" => "string", "utf16le" => "PdjqlgDe"},
      [0xD83D, 0x96EA, 0xDE00],
      ~S("\ud83d雪\ude00"),
      1
    )

    assert_session(session, os_pid, 1)
    {request, heap} = string_schema("compile:after", "compile_schema")
    assert_result(session, request, heap, receipt("compile:after", "compiled", 1))

    {request, heap} =
      string_schema("validate:after", "validate_response", %{
        "type" => "string",
        "value" => "ordinary"
      })

    assert_result(session, request, heap, receipt("validate:after", "valid", 1))
    assert_session(session, os_pid, 1)
    lone = Map.fetch!(returned, "split-empty-first-surrogate")
    assert lone == %{"type" => "string", "utf16le" => "Pdg="}
    assert Value.to_utf16le(lone) == <<0x3D, 0xD8>>

    {request, heap} = enum_schema("enum:compile", "compile_schema", lone)
    assert_result(session, request, heap, receipt("enum:compile", "compiled", 2))
    {request, heap} = enum_schema("enum:validate", "validate_response", lone)
    assert_result(session, request, heap, receipt("enum:validate", "valid", 2))
    assert_session(session, os_pid, 2)

    request = %{
      "id" => "reuse:lone",
      "kind" => "render_template",
      "template" => %{"type" => "string", "value" => "{{.}}"},
      "item" => lone
    }

    assert_render(session, request, empty_heap(), lone, [0xD83D], ~S("\ud83d"), 2)
    assert_session(session, os_pid, 2)

    request = %{
      request
      | "id" => "reuse:length",
        "template" => %{"type" => "string", "value" => "{{. | length}}"}
    }

    assert_render(
      session,
      request,
      empty_heap(),
      %{"type" => "string", "value" => "1"},
      [49],
      ~S("1"),
      2
    )

    assert_session(session, os_pid, 2)
  end

  defp assert_render(session, request, heap, expected, units, json, cache_entries) do
    result =
      assert_result(
        session,
        request,
        heap,
        Map.put(receipt(request["id"], "rendered", cache_entries), "value", expected)
      )

    raw = for unit <- units, into: <<>>, do: <<unit::unsigned-little-16>>
    assert Value.to_utf16le(result["value"]) == raw
    assert WorkflowJSON.stringify(result["value"], heap) == {:ok, json}
    assert Jason.decode!(Jason.encode!(result["value"])) == expected
    result
  end

  defp assert_result(session, request, heap, expected) do
    snapshot = :erlang.term_to_binary({request, heap})

    assert Jason.decode!(Jason.encode!(%{"request" => request, "heap" => heap})) ==
             %{"request" => request, "heap" => heap}

    assert {:ok, result} = PortSession.fulfill(session, request, heap, @operation_timeout)
    assert result == expected
    assert :erlang.term_to_binary({request, heap}) == snapshot
    result
  end

  defp assert_session(session, os_pid, cache_entries) do
    assert %{
             phase: :idle,
             os_pid: ^os_pid,
             cache_entries: ^cache_entries,
             cleanup_confirmed: false
           } = PortSession.status(session)

    assert File.exists?("/proc/#{os_pid}")
  end

  defp with_session(helper, run) do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    session =
      start_supervised!(
        {PortSession, owner_pid: self(), node_executable: node, helper_path: helper},
        id: make_ref()
      )

    assert %{phase: :dormant, os_pid: nil, cache_entries: 0} = PortSession.status(session)

    try do
      run.(session)

      assert {:ok,
              %{
                phase: :settled,
                os_pid: os_pid,
                cleanup_confirmed: true,
                exit_status: 0,
                reason: nil
              }} = PortSession.close(session)

      assert is_integer(os_pid)
      refute File.exists?("/proc/#{os_pid}")

      assert %{phase: :settled, cleanup_confirmed: true, exit_status: 0} =
               PortSession.status(session)
    after
      # Defensive cleanup for an assertion failure; no cancellation claim.
      if Process.alive?(session), do: PortSession.close(session)
    end
  end

  defp string_schema(id, kind, response \\ nil) do
    request = %{"id" => id, "kind" => kind, "schema" => %{"type" => "reference", "id" => "1"}}

    request =
      if kind == "validate_response", do: Map.put(request, "response", response), else: request

    heap = %{
      "version" => 1,
      "next_id" => 2,
      "nodes" => %{
        "1" => %{
          "type" => "object",
          "keys" => ["type"],
          "fields" => %{"type" => %{"type" => "string", "value" => "string"}}
        }
      }
    }

    {request, heap}
  end

  defp enum_schema(id, kind, lone) do
    request = %{"id" => id, "kind" => kind, "schema" => %{"type" => "reference", "id" => "1"}}

    request =
      if kind == "validate_response", do: Map.put(request, "response", lone), else: request

    heap = %{
      "version" => 1,
      "next_id" => 3,
      "nodes" => %{
        "1" => %{
          "type" => "object",
          "keys" => ["enum"],
          "fields" => %{"enum" => %{"type" => "reference", "id" => "2"}}
        },
        "2" => %{"type" => "array", "items" => [lone]}
      }
    }

    {request, heap}
  end

  defp receipt(id, outcome, cache_entries),
    do: %{
      "type" => "result",
      "id" => id,
      "result" => "ok",
      "outcome" => outcome,
      "cacheEntries" => cache_entries
    }

  defp empty_heap, do: %{"version" => 1, "next_id" => 1, "nodes" => %{}}
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
