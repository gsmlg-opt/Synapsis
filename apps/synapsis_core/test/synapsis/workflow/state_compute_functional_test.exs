defmodule Synapsis.Workflow.StateComputeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @source Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")
  @operation_timeout 15_000
  @moduletag timeout: 120_000

  # Frozen independent success literals; no Node test file or production
  # key/path/decoder algorithm constructs any expected value.
  @paths [
    {"ascii", "Session:Alpha", "captured state", "captured state/session_alpha.json"},
    {"collision-slash", "A/B", "captured state", "captured state/a_b.json"},
    {"collision-colon", "A:B", "captured state", "captured state/a_b.json"},
    {"unicode-filter", "Résumé 雪 ABC😀", "captured state", "captured state/r_sum_abc.json"},
    {"dotted-i", "İ", "captured state", "captured state/i.json"},
    {"kelvin", "K", "captured state", "captured state/k.json"},
    {"edge-underscores", "__Hello___World__", "captured state",
     "captured state/hello_world.json"},
    {"retained-punctuation", "V1.2-STATE", "captured state", "captured state/v1.2-state.json"},
    {"tagged-string", %{"type" => "string", "value" => "Tagged KEY"}, "captured state",
     "captured state/tagged_key.json"},
    {"tagged-lone-prefix", %{"type" => "string", "utf16le" => "ANhBAA=="}, "captured state",
     "captured state/a.json"},
    {"tagged-lone-middle", %{"type" => "string", "utf16le" => "QQAA3EIA"}, "captured state",
     "captured state/a_b.json"},
    {"boolean-true", true, "captured state", "captured state/true.json"},
    {"boolean-false", false, "captured state", "captured state/false.json"},
    {"finite-number", 42, "captured state", "captured state/42.json"},
    {"finite-fraction", 1.5, "captured state", "captured state/1.5.json"},
    {"relative-normalization", "KEY", "./state/../state cache//nested/.",
     "state cache/nested/key.json"},
    {"absolute-spaces", "KEY", "/tmp/state dir/a/../b", "/tmp/state dir/b/key.json"}
  ]
  @texts [
    {"pretty-lf", "7b0a2020226f6b223a20747275650a7d0a", "{\n  \"ok\": true\n}\n"},
    {"pretty-crlf", "7b0d0a2020226f6b223a20747275650d0a7d0d0a", "{\r\n  \"ok\": true\r\n}\r\n"},
    {"unicode", "e99baaf09f98800a", "雪😀\n"},
    {"bom", "efbbbf7b226f6b223a747275657d0a", "\uFEFF{\"ok\":true}\n"},
    {"empty", "", ""},
    {"raw-text", "72617720737461746520746578740a", "raw state text\n"},
    {"whitespace", "2020090a", "  \t\n"}
  ]

  test "source PortSession computes source key paths with one actual PID/cache and normal close" do
    with_session(@source, &check_paths/1)
  end

  test "source PortSession decodes captured UTF8 with one actual PID/cache and normal close" do
    with_session(@source, &check_texts/1)
  end

  test "relocated complete PortSession package computes paths with one actual PID/cache" do
    with_relocated(fn helper -> with_session(helper, &check_paths/1) end)
  end

  test "relocated complete PortSession package decodes captured UTF8 with one actual PID/cache" do
    with_relocated(fn helper -> with_session(helper, &check_texts/1) end)
  end

  defp check_paths(session) do
    pid = compile(session)
    assert length(@paths) == 17

    for {id, key, state_dir, expected} <- @paths do
      correlated = "path:" <> id

      request = %{
        "id" => correlated,
        "kind" => "state_key_path",
        "key" => key,
        "state_dir" => state_dir
      }

      assert_result(
        session,
        request,
        Map.put(receipt(correlated, "state_path"), "lexical_path", expected)
      )

      assert_session(session, pid)
    end

    validate_and_render(session, pid)
  end

  defp check_texts(session) do
    pid = compile(session)
    assert length(@texts) == 7

    for {id, hex, expected} <- @texts do
      correlated = "decode:" <> id

      request = %{
        "id" => correlated,
        "kind" => "decode_state_text",
        "bytes_base64" => hex |> Base.decode16!(case: :lower) |> Base.encode64()
      }

      result =
        assert_result(
          session,
          request,
          Map.put(receipt(correlated, "decoded"), "value", string(expected))
        )

      assert_session(session, pid)
      legacy_id = correlated <> ":legacy"

      assert_result(
        session,
        %{request | "id" => legacy_id, "kind" => "decode_template_file"},
        Map.put(receipt(legacy_id, "decoded"), "value", string(expected))
      )

      assert_result(
        session,
        schema(correlated <> ":validate", "validate_response", result["value"]),
        receipt(correlated <> ":validate", "valid")
      )

      assert_session(session, pid)
    end

    validate_and_render(session, pid)
  end

  defp compile(session) do
    assert %{phase: :dormant, os_pid: nil, cache_entries: 0} = PortSession.status(session)
    assert_result(session, schema("compile", "compile_schema"), receipt("compile", "compiled"))
    assert %{phase: :idle, os_pid: pid, cache_entries: 1} = PortSession.status(session)
    assert is_integer(pid)
    assert_session(session, pid)
    pid
  end

  defp validate_and_render(session, pid) do
    assert_result(
      session,
      schema("validate:after", "validate_response", string("ordinary")),
      receipt("validate:after", "valid")
    )

    assert_result(
      session,
      %{
        "id" => "render:after",
        "kind" => "render_template",
        "template" => string("[{{.}}]"),
        "item" => string("雪😀")
      },
      Map.put(receipt("render:after", "rendered"), "value", string("[雪😀]"))
    )

    assert_result(
      session,
      schema("compile:reuse", "compile_schema"),
      receipt("compile:reuse", "compiled")
    )

    assert_session(session, pid)
  end

  defp assert_result(session, request, expected) do
    heap = heap()
    snapshot = :erlang.term_to_binary({request, heap})

    assert Jason.decode!(Jason.encode!(%{"request" => request, "heap" => heap})) ==
             %{"request" => request, "heap" => heap}

    assert {:ok, result} = PortSession.fulfill(session, request, heap, @operation_timeout)
    assert result == expected
    assert :erlang.term_to_binary({request, heap}) == snapshot
    assert heap["nodes"]["2"]["fields"]["private"] == %{"type" => "string", "utf16le" => "ANg="}
    result
  end

  defp assert_session(session, pid) do
    assert %{phase: :idle, os_pid: ^pid, cache_entries: 1, cleanup_confirmed: false} =
             PortSession.status(session)

    assert File.exists?("/proc/#{pid}")
  end

  defp with_session(helper, run) do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    session =
      start_supervised!(
        {PortSession, owner_pid: self(), node_executable: node, helper_path: helper},
        id: make_ref()
      )

    try do
      run.(session)
    after
      # Always request the existing normal close, including after the expected
      # unsupported-operation baseline assertion. No linked Task or cancel.
      assert Process.alive?(session)
      before_close = PortSession.status(session)

      assert {:ok, %{phase: :settled, cleanup_confirmed: true} = closed} =
               PortSession.close(session)

      if is_integer(before_close.os_pid) do
        assert closed.os_pid == before_close.os_pid
        assert closed.exit_status == 0
        assert closed.reason == nil
        refute File.exists?("/proc/#{before_close.os_pid}")
      end

      assert %{phase: :settled, cleanup_confirmed: true} = PortSession.status(session)
    end
  end

  defp with_relocated(run) do
    staged = System.fetch_env!("SYNAPSIS_WORKFLOW_STATE_HELPER_ROOT")
    assert Path.type(staged) == :absolute
    root = Path.join(System.tmp_dir!(), "synapsis-state-compute-" <> Ecto.UUID.generate())
    assembled = Path.join(root, "assembled complete helper")
    relocated = Path.join(root, "relocated complete helper")
    File.mkdir_p!(root)

    try do
      assert {:ok, _} = File.cp_r(staged, assembled)
      assert :ok = File.rename(assembled, relocated)
      refute File.exists?(assembled)
      paths = files(staged)
      assert length(paths) == 599
      assert files(relocated) == paths
      assert "schema-stdio.mjs" in paths
      assert "schema-worker.mjs" in paths

      for path <- paths do
        assert File.read!(Path.join(relocated, path)) == File.read!(Path.join(staged, path))
      end

      run.(Path.join(relocated, "schema-stdio.mjs"))
    after
      File.rm_rf!(root)
    end
  end

  defp files(root, prefix \\ "") do
    root
    |> Path.join(prefix)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      relative = Path.join(prefix, name)

      case File.lstat!(Path.join(root, relative)).type do
        :directory -> files(root, relative)
        :regular -> [relative]
      end
    end)
    |> Enum.sort()
  end

  defp schema(id, kind, response \\ nil) do
    request = %{"id" => id, "kind" => kind, "schema" => %{"type" => "reference", "id" => "1"}}
    if kind == "validate_response", do: Map.put(request, "response", response), else: request
  end

  defp heap do
    %{
      "version" => 1,
      "next_id" => 3,
      "nodes" => %{
        "1" => %{
          "type" => "object",
          "keys" => ["type"],
          "fields" => %{"type" => string("string")}
        },
        "2" => %{
          "type" => "object",
          "keys" => ["private"],
          "fields" => %{"private" => %{"type" => "string", "utf16le" => "ANg="}}
        }
      }
    }
  end

  defp string(value), do: %{"type" => "string", "value" => value}

  defp receipt(id, outcome) do
    %{"type" => "result", "id" => id, "result" => "ok", "outcome" => outcome, "cacheEntries" => 1}
  end
end
