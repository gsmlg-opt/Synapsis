defmodule Synapsis.Workflow.SchemaFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.{Machine, Schema, Value}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @fixture_path Path.join(
                  @root,
                  "packages/tool-host/test/fixtures/workflow-schema-cases.json"
                )
  @external_resource @fixture_path
  @cases @fixture_path |> File.read!() |> Jason.decode!()
  @operation_timeout 15_000

  @moduletag timeout: 120_000

  # Independently authored and archived before the product implementation.
  # Every schema acknowledgement in this file comes from the actual helper
  # through PortSession or Schema.advance_pending; no fixture acknowledges it.

  test "the actual session compiles four normal schemas and validates 34 literal responses" do
    assert length(@cases["compile_cases"]) == 4
    assert length(@cases["validation_cases"]) == 34

    with_session(fn session ->
      for {item, index} <- Enum.with_index(@cases["compile_cases"]) do
        assert item["expected"] == "compiled"
        id = "compile:#{index}"
        {request, heap} = request(id, "compile_schema", item["schema"])

        assert {:ok, %{"id" => ^id, "result" => "ok", "outcome" => "compiled"}} =
                 PortSession.fulfill(session, request, heap, @operation_timeout)
      end

      for {item, index} <- Enum.with_index(@cases["validation_cases"]) do
        assert item["expected_valid"] == true
        id = "validate:#{index}"

        {request, heap} =
          request(id, "validate_response", item["schema"], item["response_json"])

        if bits = item["expected_number_bits"], do: assert(request["response"]["bits"] == bits)

        assert {:ok, %{"id" => ^id, "result" => "ok", "outcome" => "valid"}} =
                 PortSession.fulfill(session, request, heap, @operation_timeout)

        if expected = item["expected_unchanged_response_json"] do
          assert public(request["response"], heap) == Jason.decode!(expected)
          assert Value.object_keys(request["response"], heap) == ["label", "note"]
          assert Value.object_get(request["response"], "count", heap) == Value.undefined()
        end
      end

      assert %{phase: :idle, os_pid: os_pid, cache_entries: entries} = PortSession.status(session)
      assert is_integer(os_pid)
      assert entries >= 1
      assert File.exists?("/proc/#{os_pid}")
    end)
  end

  test "actual validation carries ask through checkpoint and same-session resume to head and pick" do
    item = hd(@cases["machine_cases"])

    with_session(fn session ->
      assert {:ok, input, heap} = Value.decode_json(item["input_json"])

      assert {:ok, machine} =
               Machine.new(
                 item["parsed_program"],
                 %{
                   "kind" => item["input_kind"],
                   "items" => Value.array_items(input, heap)
                 },
                 heap,
                 item["options"]
               )

      assert {:checkpoint, checkpoint, suspended, before_requests} =
               run_to_boundary(machine, session)

      assert before_requests == item["expected_request_boundaries_before_checkpoint"]
      assert checkpoint["mode"] == item["expected_checkpoint_mode"]
      assert checkpoint["stage_index"] == item["expected_checkpoint_stage_index"]

      assert Enum.map(checkpoint["replay_items"], &public(&1, suspended["heap"])) ==
               Jason.decode!(item["expected_checkpoint_replay_items_json"])

      envelope = public(checkpoint["request"], suspended["heap"])
      assert envelope["subject"] == item["expected_checkpoint_subject"]
      assert envelope["prompt"] == "Continue with metadata"

      assert %{phase: :idle, os_pid: helper_pid, cache_entries: 1, cleanup_confirmed: false} =
               PortSession.status(session)

      assert is_integer(helper_pid)
      assert File.exists?("/proc/#{helper_pid}")

      # Only the pure state/heap is snapshotted. The caller explicitly retains
      # this exact session and its compiler cache across the semantic boundary.
      restored = suspended |> Jason.encode!() |> Jason.decode!()
      assert restored == suspended
      assert {:ok, response, heap} = Value.decode_json(item["response_json"], restored["heap"])
      restored = Map.put(restored, "heap", heap)
      assert {:ok, resumed} = Machine.resume(restored, response)

      assert {:complete, result, completed, after_requests} =
               run_to_boundary(resumed, session)

      assert after_requests == item["expected_request_boundaries_after_resume"]

      assert Enum.map(result["items"], &public(&1, completed["heap"])) ==
               Jason.decode!(item["expected_result_items_json"])

      assert result["rendered"] == item["expected_result_rendered"]
      assert result["rendered_items"] == item["expected_result_rendered_items"]
      assert result["stdout"] == item["expected_result_stdout"]

      assert %{phase: :idle, os_pid: ^helper_pid, cache_entries: 1, cleanup_confirmed: false} =
               PortSession.status(session)

      assert File.exists?("/proc/#{helper_pid}")
    end)
  end

  defp with_session(run) do
    node = System.find_executable("node")
    assert is_binary(node)

    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: node,
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")}
      )

    assert %{
             phase: :dormant,
             os_pid: nil,
             cache_entries: 0,
             cleanup_confirmed: false
           } = PortSession.status(session)

    try do
      run.(session)
    after
      assert {:ok,
              %{
                phase: :settled,
                os_pid: helper_pid,
                cleanup_confirmed: true,
                exit_status: 0
              }} = PortSession.close(session)

      assert is_integer(helper_pid)
      refute File.exists?("/proc/#{helper_pid}")

      assert %{phase: :settled, cleanup_confirmed: true, exit_status: 0} =
               PortSession.status(session)
    end
  end

  defp request(id, kind, schema, response_json \\ nil) do
    assert {:ok, schema, heap} = schema |> Jason.encode!() |> Value.decode_json()
    request = %{"id" => id, "kind" => kind, "boundary" => "ordinary_literal", "schema" => schema}

    if kind == "validate_response" do
      assert {:ok, response, heap} = Value.decode_json(response_json, heap)
      {Map.put(request, "response", response), heap}
    else
      {request, heap}
    end
  end

  defp run_to_boundary(state, session, requests \\ [], remaining \\ 2_000)

  defp run_to_boundary(state, session, requests, remaining) when remaining > 0 do
    case Machine.advance(state) do
      {:continue, next} ->
        run_to_boundary(next, session, requests, remaining - 1)

      {:request, request, pending} ->
        assert Machine.advance(pending) == {:request, request, pending}

        if request["boundary"] == "saved_response", do: assert(pending["frames"] == [])

        assert {:continue, next} =
                 Schema.advance_pending(session, pending, @operation_timeout)

        recorded = Map.take(request, ["kind", "boundary"])
        run_to_boundary(next, session, requests ++ [recorded], remaining - 1)

      {:checkpoint, checkpoint, next} ->
        {:checkpoint, checkpoint, next, requests}

      {:complete, result, next} ->
        {:complete, result, next, requests}

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp run_to_boundary(_state, _session, _requests, 0),
    do: flunk("ordinary transition bound exceeded")

  defp public(value, heap) do
    assert {:ok, text} = WorkflowJSON.stringify(value, heap)
    Jason.decode!(text)
  end
end
