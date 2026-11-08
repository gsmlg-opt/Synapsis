defmodule Synapsis.Workflow.SegmentEffectFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Journal, Machine, Schema, Segment, Value}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @moduletag timeout: 120_000
  @workflow_id "b59a09ba-c6f1-469d-93d9-e745b2f4d233"
  @first ~S({"content":[{"type":"text","text":"first\n"}],"details":{"kind":"text","content":"first\n"}})
  @second ~S({"details":{"content":"second\n","kind":"text"},"content":[{"text":"second\n","type":"text"}]})
  @origin %{
    "namespace" => "fixture-segment-store",
    "store_incarnation" => 1,
    "parent_run_id" => "fixture-parent-run",
    "parent_incarnation" => 1,
    "parent_invocation_id" => "fixture-parent-invocation",
    "caller" => "fixture-caller",
    "resource_owner_id" => "fixture-owner",
    "resource_incarnation" => 1
  }

  # These origin/reference literals are pure journal fixtures, not native
  # authority or receipts. The actual pending requests come from Machine.invoke.
  # Raw consumer JSON is deliberately supplied with literal property order.
  test "two effects retain the exact pending Machine and consume each result in one revision" do
    pipeline =
      ~S(openclaw.invoke --tool synapsis::read --action read --args-json '{"path":"first.txt"}' | clawd.invoke --tool synapsis::read --action read --args-json '{"path":"second.txt"}')

    assert {:ok, legacy} = Segment.new(pipeline)
    assert legacy["version"] == 1
    assert Enum.sort(Map.keys(legacy)) == ~w(journal kind machine revision source version)
    assert {:ok, initial} = Segment.new(pipeline, version: 2)
    assert initial == Map.merge(legacy, %{"version" => 2, "consumed_effects" => 0})
    assert {:ok, %{journal: journal, consumed_effects: 0}} = Segment.inspect_snapshot(initial)
    assert journal === Journal.new()
    assert roundtrip(initial) === initial

    {:request, first_request, awaiting} = boundary(initial)
    assert first_request == invoke("invoke:1", "openclaw.invoke", 0, 0, "first.txt")
    assert awaiting["revision"] == 1
    assert awaiting["machine"] !== initial["machine"]
    assert awaiting["machine"]["pending_request"] === first_request
    assert awaiting["machine"]["phase"] == "request"
    assert Segment.advance(awaiting) === {:request, first_request, awaiting}

    first = prepare_settle_consume(awaiting, first_request, 2, @first)
    assert first.pending["revision"] == 2
    assert first.settled["revision"] == 3
    assert first.consumed["revision"] == 4
    assert first.consumed["consumed_effects"] == 1
    assert first.consumed["machine"]["pending_request"] == nil
    assert first.consumed["machine"]["next_request"] == 2

    {:request, second_request, awaiting_second} = boundary(roundtrip(first.consumed))
    assert second_request == invoke("invoke:2", "clawd.invoke", 0, 1, "second.txt")
    assert awaiting_second["revision"] == 4
    assert awaiting_second["journal"] === first.settled["journal"]
    assert awaiting_second["consumed_effects"] == 1

    second = prepare_settle_consume(awaiting_second, second_request, 5, @second)
    assert second.pending["revision"] == 5
    assert second.settled["revision"] == 6
    assert second.consumed["revision"] == 7
    assert second.consumed["consumed_effects"] == 2
    assert hd(second.consumed["journal"]["effects"]) === hd(first.settled["journal"]["effects"])

    assert {:ok, %{journal: inspected, consumed_effects: 2}} =
             Segment.inspect_snapshot(roundtrip(second.consumed))

    assert inspected === second.settled["journal"]

    {:complete, _, completed} = boundary(second.consumed)
    assert completed["revision"] == 7
    assert completed["journal"] === second.settled["journal"]
    assert completed["consumed_effects"] == 2
    assert {:ok, envelope} = Segment.envelope(completed, "unused")

    assert envelope == %{
             "ok" => true,
             "status" => "ok",
             "output" => [Jason.decode!(@second)],
             "requiresApproval" => nil
           }

    [item] = completed["machine"]["items"]
    assert Value.object_keys(item, completed["machine"]["heap"]) == ["details", "content"]
  end

  test "an effect before ask stays consumed across a fresh schema helper and explicit resume" do
    pipeline =
      ~S(openclaw.invoke --tool synapsis::read --action read --args-json '{"path":"first.txt"}' | ask --prompt Review --schema '{"type":"string"}' --emit | clawd.invoke --tool synapsis::read --action read --args-json '{"path":"second.txt"}')

    assert {:ok, initial} = Segment.new(pipeline, version: 2)
    {:request, first_request, awaiting} = boundary(initial)
    first = prepare_settle_consume(awaiting, first_request, 2, @first)

    {{:checkpoint, checkpoint, suspended}, first_pid} =
      with_helper(fn helper -> schema_boundary(first.consumed, helper) end)

    assert checkpoint["mode"] == "next_stage"
    assert checkpoint["stage_index"] == 1
    assert suspended["revision"] == 4
    assert suspended["consumed_effects"] == 1
    assert suspended["journal"] === first.settled["journal"]
    assert suspended["machine"]["next_request"] == 3
    assert {:ok, %{"status" => "needs_input"}} = Segment.envelope(suspended, "fixture-locator")
    assert {:ok, resumed} = Segment.resume(roundtrip(suspended), ~S("approved"))
    assert resumed["source"] === initial["source"]
    assert resumed["journal"] === first.settled["journal"]
    assert resumed["consumed_effects"] == 1
    assert resumed["machine"]["segment"] == 1
    assert Enum.map(resumed["machine"]["program"], & &1["name"]) == ["clawd.invoke"]

    {{second_request, awaiting_second}, second_pid} =
      with_helper(fn helper ->
        ready = schema_ready(resumed, helper)
        assert Segment.resume_ready?(ready)
        assert ready["journal"] === first.settled["journal"]
        assert ready["consumed_effects"] == 1
        assert {:request, request, awaiting} = boundary(ready)
        {request, awaiting}
      end)

    assert is_integer(first_pid) and is_integer(second_pid) and first_pid != second_pid
    assert second_request == invoke("invoke:5", "clawd.invoke", 1, 0, "second.txt")
    assert awaiting_second["revision"] == 4
    second = prepare_settle_consume(awaiting_second, second_request, 5, @second)
    {:complete, _, completed} = boundary(second.consumed)
    assert completed["revision"] == 7
    assert completed["consumed_effects"] == 2
    assert hd(completed["journal"]["effects"]) === hd(first.settled["journal"]["effects"])
    assert {:ok, %{"status" => "ok", "output" => output}} = Segment.envelope(completed, "unused")
    assert output == [Jason.decode!(@second)]
  end

  defp prepare_settle_consume(awaiting, request, pending_revision, raw) do
    body = Jason.decode!(request["body"])

    native = %{
      correlation: %{
        workflow_id: @workflow_id,
        request_id: request["id"],
        segment: request["segment"]
      },
      target: %{tool_name: body["tool"], tool_revision: 1, arguments: body["args"]},
      limits: %{
        timeout_ms: 20_000,
        effect_timeout_ms: 15_000,
        commit_timeout_ms: 5_000,
        cleanup_timeout_ms: 5_000,
        output_limit: 65_536,
        work: 4
      }
    }

    assert {:ok, encoded} = Journal.encode_request(native)

    assert {:ok, pending} =
             Segment.prepare_effect(roundtrip(awaiting), pending_revision, encoded, @origin)

    entry = %{
      "state" => "pending",
      "pending_revision" => pending_revision,
      "request" => encoded,
      "origin" => @origin
    }

    assert List.last(pending["journal"]["effects"]) === entry
    assert pending["machine"] === awaiting["machine"]
    assert pending["source"] === awaiting["source"]
    assert pending["consumed_effects"] === awaiting["consumed_effects"]
    assert roundtrip(pending) === pending
    assert Segment.advance(pending) === {:request, request, pending}

    reference = %{
      "kind" => "workflow_effect_receipt",
      "fact_id" => @workflow_id <> ":" <> Integer.to_string(pending_revision),
      "namespace" => "fixture-segment-store",
      "run_id" => "fixture-native-" <> Integer.to_string(pending_revision),
      "incarnation" => 1,
      "final_revision" => 19
    }

    assert {:ok, settled} =
             Segment.settle_effect(
               roundtrip(pending),
               pending_revision,
               pending_revision + 1,
               reference
             )

    assert List.last(settled["journal"]["effects"]) ===
             Map.merge(entry, %{
               "state" => "settled",
               "settled_revision" => pending_revision + 1,
               "receipt" => reference
             })

    assert settled["machine"] === awaiting["machine"]
    assert settled["consumed_effects"] === awaiting["consumed_effects"]
    assert roundtrip(settled) === settled
    assert Segment.advance(settled) === {:request, request, settled}

    assert {:continue, expected_machine} =
             Machine.advance(awaiting["machine"], %{"id" => request["id"], "response_json" => raw})

    assert {:ok, consumed} =
             Segment.consume_effect(roundtrip(settled), pending_revision + 2, request["id"], raw)

    assert consumed ===
             Map.merge(settled, %{
               "revision" => pending_revision + 2,
               "machine" => expected_machine,
               "consumed_effects" => awaiting["consumed_effects"] + 1
             })

    assert roundtrip(consumed) === consumed
    %{pending: pending, settled: settled, consumed: consumed}
  end

  defp invoke(id, command, segment, stage, path),
    do: %{
      "id" => id,
      "kind" => "invoke",
      "command" => command,
      "segment" => segment,
      "stage_index" => stage,
      "body" => ~s({"tool":"synapsis::read","action":"read","args":{"path":"#{path}"}})
    }

  defp boundary(snapshot, remaining \\ 10_000)
  defp boundary(_, 0), do: flunk("ordinary Segment transition helper exhausted")

  defp boundary(snapshot, remaining) do
    case Segment.advance(snapshot) do
      {:continue, next} -> boundary(next, remaining - 1)
      {kind, _, _} = result when kind in [:request, :checkpoint, :complete] -> result
      other -> flunk("unexpected ordinary Segment transition: #{inspect(other)}")
    end
  end

  defp schema_boundary(snapshot, helper) do
    case boundary(snapshot) do
      {:request, %{"kind" => kind}, pending}
      when kind in ["compile_schema", "validate_response"] ->
        assert {:continue, machine} = Schema.advance_pending(helper, pending["machine"], 15_000)
        schema_boundary(Map.put(pending, "machine", machine), helper)

      result ->
        result
    end
  end

  defp schema_ready(snapshot, helper, remaining \\ 10_000)
  defp schema_ready(_, _, 0), do: flunk("ordinary Segment resume helper exhausted")

  defp schema_ready(snapshot, helper, remaining) do
    if Segment.resume_ready?(snapshot) do
      snapshot
    else
      case Segment.advance(snapshot) do
        {:continue, next} ->
          schema_ready(next, helper, remaining - 1)

        {:request, %{"kind" => kind}, pending}
        when kind in ["compile_schema", "validate_response"] ->
          assert {:continue, machine} = Schema.advance_pending(helper, pending["machine"], 15_000)
          schema_ready(Map.put(pending, "machine", machine), helper, remaining - 1)

        other ->
          flunk("unexpected ordinary Segment resume: #{inspect(other)}")
      end
    end
  end

  defp with_helper(fun) do
    helper =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")},
        id: make_ref()
      )

    try do
      result = fun.(helper)
      assert {:ok, %{cleanup_confirmed: true, os_pid: os_pid}} = PortSession.close(helper)
      if os_pid, do: refute(File.exists?("/proc/#{os_pid}"))
      {result, os_pid}
    after
      if Process.alive?(helper), do: PortSession.close(helper)
    end
  end

  defp roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
