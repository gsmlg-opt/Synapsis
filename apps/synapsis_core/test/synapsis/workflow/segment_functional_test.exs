defmodule Synapsis.Workflow.SegmentFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Schema, Segment}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @fixture Path.expand("../../fixtures/workflow_segment_cases.json", __DIR__)
  @external_resource @fixture
  @fixtures @fixture |> File.read!() |> Jason.decode!()
  @moduletag timeout: 120_000

  # Literal ordinary expectations were frozen before the Segment modules.
  # All schema receipts below come from the actual validation-only helper.
  test "inline segments retain complete checkpoints and resume with a fresh helper" do
    for item <- @fixtures["cases"] do
      assert {:ok, initial} = Segment.new(item["pipeline"])

      assert Map.keys(initial) |> Enum.sort() ==
               Enum.sort(~w(kind version revision source machine journal))

      assert initial["kind"] == "workflow_segment"
      assert initial["version"] == 1
      assert initial["revision"] == 1
      assert initial["source"] == %{"kind" => "inline", "pipeline" => item["pipeline"]}
      assert initial["journal"] == %{"kind" => "workflow", "version" => 1, "effects" => []}
      assert initial["machine"]["heap"] == %{"version" => 1, "next_id" => 1, "nodes" => %{}}
      assert initial["machine"]["options"] == %{"render_output" => false}
      assert initial["machine"]["streams"]["s0"]["kind"] == "iterator_items"
      assert initial["machine"]["streams"]["s0"]["items"] == []
      assert Enum.map(initial["machine"]["program"], & &1["name"]) == item["program"]

      {kind, boundary, requests, first_pid} =
        with_helper(fn helper -> drive(initial, helper, false) end)

      assert requests == item["before_requests"]
      assert boundary["journal"] == initial["journal"]
      restored = boundary |> Jason.encode!() |> Jason.decode!()
      assert restored === boundary
      assert restored["machine"]["heap"] === boundary["machine"]["heap"]

      if item["name"] == "complete" do
        assert kind == :complete

        assert {:ok, %{"ok" => true, "status" => "ok", "output" => [], "requiresApproval" => nil}} =
                 Segment.envelope(restored, "unused")
      else
        assert kind == :checkpoint
        checkpoint = restored["machine"]["checkpoint"]
        assert checkpoint["mode"] == item["mode"]
        assert checkpoint["stage_index"] == item["stage_index"]
        assert checkpoint["replay_items"] == []

        assert checkpoint["halted_at"] ==
                 %{"index" => 1, "name" => "ask", "in_place" => item["mode"] == "same_stage"}

        assert {:ok, envelope} = Segment.envelope(restored, "literal-host-locator")

        assert envelope == %{
                 "ok" => true,
                 "status" => "needs_input",
                 "output" => [],
                 "requiresApproval" => nil,
                 "requiresInput" => %{
                   "type" => "input_request",
                   "prompt" => "Choose tag",
                   "responseSchema" => @fixtures["schema"],
                   "resumeToken" => "literal-host-locator"
                 }
               }

        assert {:ok, resuming} = Segment.resume(restored, item["response_json"])
        assert Enum.map(resuming["machine"]["program"], & &1["name"]) == item["resumed_program"]
        assert resuming["source"] == initial["source"]
        assert resuming["machine"]["segment"] == 1
        assert resuming["machine"]["frames"] == []
        refute Segment.resume_ready?(resuming)

        {{ready, completed, claim_requests, after_requests}, second_pid} =
          with_helper_raw(fn helper ->
            assert {:ready, ready, claim_requests} = drive(resuming, helper, true)
            assert Segment.resume_ready?(ready)
            assert ready["machine"]["frames"] == []
            assert ready["machine"]["stack"] == [%{"op" => "construct"}]
            assert {:complete, completed, after_requests} = drive(ready, helper, false)
            {ready, completed, claim_requests, after_requests}
          end)

        assert is_integer(first_pid) and is_integer(second_pid) and first_pid != second_pid
        assert claim_requests == item["claim_requests"]
        assert after_requests == item["after_requests"]
        assert completed["machine"]["program"] === ready["machine"]["program"]
        assert completed["journal"] == initial["journal"]
        assert {:ok, result} = Segment.envelope(completed, "unused")

        assert result == %{
                 "ok" => true,
                 "status" => "ok",
                 "output" => item["output"],
                 "requiresApproval" => nil
               }
      end
    end
  end

  defp drive(snapshot, helper, stop_ready, requests \\ []) do
    if stop_ready and Segment.resume_ready?(snapshot) do
      {:ready, snapshot, requests}
    else
      case Segment.advance(snapshot) do
        {:continue, next} ->
          drive(next, helper, stop_ready, requests)

        {:request, request, pending} ->
          assert {:continue, machine} = Schema.advance_pending(helper, pending["machine"], 15_000)
          next = Map.put(pending, "machine", machine)
          drive(next, helper, stop_ready, requests ++ [[request["kind"], request["boundary"]]])

        {:checkpoint, _checkpoint, next} ->
          {:checkpoint, next, requests}

        {:complete, _result, next} ->
          {:complete, next, requests}

        other ->
          flunk("unexpected ordinary transition: #{inspect(other)}")
      end
    end
  end

  defp with_helper(fun) do
    {{kind, snapshot, requests}, os_pid} = with_helper_raw(fun)
    {kind, snapshot, requests, os_pid}
  end

  defp with_helper_raw(fun) do
    helper =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")},
        id: make_ref()
      )

    assert %{phase: :dormant, os_pid: nil} = PortSession.status(helper)

    try do
      result = fun.(helper)
      assert {:ok, %{cleanup_confirmed: true, os_pid: os_pid}} = PortSession.close(helper)
      if os_pid, do: refute(File.exists?("/proc/#{os_pid}"))
      {result, os_pid}
    after
      if Process.alive?(helper), do: PortSession.close(helper)
    end
  end
end
