defmodule Synapsis.Workflow.SegmentStateJournalFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Journal, Live, Machine, Segment}
  alias Synapsis.Workflow.Provenance.Owner

  @workflow_id "b59a09ba-c6f1-469d-93d9-e745b2f4d233"
  @scope %{
    "kind" => "trusted_internal",
    "project_root" => "/ordinary/admitted",
    "state_dir" => "state/source-spelling",
    "process_cwd" => "/ordinary/admitted"
  }
  @origin %{
    "namespace" => "fixture-state-store",
    "store_incarnation" => 1,
    "parent_run_id" => "fixture-parent-run",
    "parent_incarnation" => 1,
    "parent_invocation_id" => "fixture-parent-invocation",
    "caller" => "fixture-caller",
    "resource_owner_id" => "fixture-owner",
    "resource_incarnation" => 1
  }

  # These references are pure journal fixtures. The admitted driver tests own
  # evidence of actual file IO, immutable facts, registration and retirement.
  test "opt-in v3 keeps its exact scope and starts a tagged operations journal" do
    pipeline = "state.get seed"
    assert {:ok, legacy} = Segment.new(pipeline)
    assert legacy["version"] == 1
    assert legacy["journal"] == Journal.new()
    assert Enum.sort(Map.keys(legacy)) == ~w(journal kind machine revision source version)

    assert {:ok, snapshot} = Segment.new(pipeline, version: 3, state_scope: @scope)

    assert Enum.sort(Map.keys(snapshot)) ==
             ~w(consumed_operations journal kind machine revision source version)

    assert snapshot["kind"] == "workflow_segment"
    assert snapshot["version"] == 3
    assert snapshot["revision"] == 1
    assert snapshot["machine"] === legacy["machine"]

    assert snapshot["source"] == %{
             "kind" => "inline",
             "pipeline" => pipeline,
             "state_scope" => @scope
           }

    assert snapshot["journal"] == %{"kind" => "workflow", "version" => 2, "operations" => []}
    assert snapshot["journal"] == Journal.new_operations()
    assert {:ok, []} = Journal.inspect_operations(snapshot["journal"])
    assert snapshot["consumed_operations"] == 0
    assert {:ok, _} = Segment.inspect_snapshot(snapshot)
    assert roundtrip(snapshot) === snapshot
  end

  test "get set and diff retain their waiting Machine through settlement and consume one observed ACK" do
    assert {:ok, snapshot} =
             Segment.new("state.get seed | state.set saved | diff.last comparison",
               version: 3,
               state_scope: @scope
             )

    {:request, get, waiting} = boundary(snapshot)
    assert get == %{"id" => "state:1", "kind" => "state_get", "key" => "seed", "stage_index" => 0}

    first =
      transition(waiting, get, %{
        "id" => get["id"],
        "kind" => "state_get",
        "result" => "ok",
        "text" => "1\n"
      })

    assert [{:state_read, "state:1", value, "1\n"}] = first.observations
    assert value == %{"type" => "number", "bits" => "3ff0000000000000"}

    {:request, set, waiting} = boundary(roundtrip(first.consumed))
    assert set["id"] == "state:2"
    assert set["kind"] == "state_set"
    assert set["key"] == "saved"
    assert set["value"] === value
    assert set["text"] == "1\n"

    second =
      transition(waiting, set, %{"id" => set["id"], "kind" => "state_set", "result" => "ok"})

    assert second.observations == [{:state_written, "state:2", value, "1\n"}]

    {:request, diff, waiting} = boundary(roundtrip(second.consumed))
    assert diff["id"] == "state:3"
    assert diff["kind"] == "state_diff"
    assert diff["key"] == "comparison"
    assert diff["value"] === value
    assert diff["text"] == "1\n"

    third =
      transition(waiting, diff, %{
        "id" => diff["id"],
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "0\n",
        "changed" => true
      })

    assert third.observations == []
    assert third.consumed["revision"] == 10
    assert third.consumed["consumed_operations"] == 3

    assert Enum.map(third.consumed["journal"]["operations"], & &1["pending_revision"]) == [
             2,
             5,
             8
           ]

    assert {:complete, _, completed} = boundary(third.consumed)
    assert {:ok, envelope} = Segment.envelope(completed, "unused")
    assert envelope["status"] == "ok"

    assert envelope["output"] == [
             %{
               "kind" => "diff.last",
               "key" => "comparison",
               "changed" => true,
               "before" => 0,
               "after" => 1
             }
           ]
  end

  test "a serialized consumed prefix preserves original requests and separate state receipt references" do
    assert {:ok, snapshot} =
             Segment.new("state.get seed | state.set saved", version: 3, state_scope: @scope)

    {:request, get, waiting} = boundary(snapshot)

    first =
      transition(waiting, get, %{
        "id" => get["id"],
        "kind" => "state_get",
        "result" => "ok",
        "text" => "{\"b\":2,\"a\":1}\n"
      })

    retained = roundtrip(first.consumed)
    {:request, set, waiting} = boundary(retained)

    second =
      transition(waiting, set, %{"id" => set["id"], "kind" => "state_set", "result" => "ok"})

    [retained_entry, next_entry] = second.consumed["journal"]["operations"]
    assert retained_entry === hd(retained["journal"]["operations"])
    assert retained_entry["request"]["semantic"] === get
    assert next_entry["request"]["semantic"] === set
    assert set["text"] == "{\n  \"b\": 2,\n  \"a\": 1\n}\n"
    assert retained_entry["receipt"]["kind"] == "workflow_state_receipt"
    assert next_entry["receipt"]["fact_id"] == @workflow_id <> ":state:5"
    assert roundtrip(second.consumed) === second.consumed
    assert second.consumed["source"]["state_scope"] === @scope
    assert {:ok, _} = Segment.inspect_snapshot(second.consumed)
  end

  test "publishing an already observed transition does not advance Machine and retires the original lease" do
    owner = start_supervised!({Owner, name: nil})
    assert {:ok, snapshot} = Segment.new("state.get seed", version: 3, state_scope: @scope)
    machine = snapshot["machine"]
    assert {:ok, original} = Live.open(owner, machine, 5_000)
    {transition, observations} = Machine.advance_observed(machine)
    parent = self()

    publisher =
      spawn(fn ->
        receive do
          :publish ->
            result =
              Live.publish_observed(original, machine, {transition, observations}, nil, 5_000)

            barrier = :erlang.trace_delivered(self())

            receive do
              {:trace_delivered, _, ^barrier} -> :ok
            after
              5_000 -> raise "publication trace did not drain"
            end

            send(parent, {:published_once, result})
        end
      end)

    target = {Machine, :advance_observed, 2}
    Code.ensure_loaded!(Machine)
    assert :erlang.trace_pattern(target, true, [:local]) > 0
    assert :erlang.trace(publisher, true, [:call, {:tracer, self()}]) == 1
    on_exit(fn -> :erlang.trace_pattern(target, false, [:local]) end)
    send(publisher, :publish)
    assert_receive {:published_once, {:ok, ^transition, current}}, 5_000
    refute_receive {:trace, ^publisher, :call, {Machine, :advance_observed, _}}, 0
    assert current.seq == original.seq + 1
    assert current.lease === original.lease
    assert :ok = Live.retire(original, 5_000)
    assert :sys.get_state(owner).leases == %{}
    assert Process.alive?(owner)
  end

  defp transition(waiting, semantic, ack) do
    pending_revision = waiting["revision"] + 1

    encoded = %{
      "correlation" => %{
        "workflow_id" => @workflow_id,
        "request_id" => semantic["id"],
        "segment" => waiting["machine"]["segment"]
      },
      "semantic" => semantic,
      "scope" => @scope,
      "target" => %{
        "lexical_path" => "state/source-spelling/" <> semantic["key"] <> ".json",
        "absolute_path" =>
          "/ordinary/admitted/state/source-spelling/" <> semantic["key"] <> ".json",
        "relative_path" => "state/source-spelling/" <> semantic["key"] <> ".json"
      }
    }

    host_request = %{
      correlation: %{
        workflow_id: @workflow_id,
        request_id: semantic["id"],
        segment: waiting["machine"]["segment"]
      },
      semantic: semantic,
      scope: @scope,
      target: %{
        lexical_path: encoded["target"]["lexical_path"],
        absolute_path: encoded["target"]["absolute_path"],
        relative_path: encoded["target"]["relative_path"]
      }
    }

    assert {:ok, ^encoded} = Journal.encode_state_request(host_request)
    assert {:ok, ^host_request} = Journal.decode_state_request(encoded)

    assert {:ok, pending} =
             Segment.prepare_operation(
               roundtrip(waiting),
               pending_revision,
               :state_operation,
               encoded,
               @origin
             )

    entry = %{
      "type" => "state_operation",
      "state" => "pending",
      "pending_revision" => pending_revision,
      "request" => encoded,
      "origin" => @origin
    }

    assert List.last(pending["journal"]["operations"]) === entry
    assert pending["machine"] === waiting["machine"]
    assert pending["consumed_operations"] === waiting["consumed_operations"]

    reference = %{
      "kind" => "workflow_state_receipt",
      "version" => 1,
      "fact_id" => @workflow_id <> ":state:" <> Integer.to_string(pending_revision),
      "namespace" => @origin["namespace"],
      "incarnation" => @origin["store_incarnation"]
    }

    assert {:ok, settled} =
             Segment.settle_operation(
               roundtrip(pending),
               pending_revision,
               pending_revision + 1,
               reference
             )

    assert settled["machine"] === waiting["machine"]
    assert settled["consumed_operations"] === waiting["consumed_operations"]

    assert List.last(settled["journal"]["operations"]) ===
             Map.merge(entry, %{
               "state" => "settled",
               "settled_revision" => pending_revision + 1,
               "receipt" => reference
             })

    assert Segment.advance_observed(settled) === {{:request, semantic, settled}, []}

    {{:continue, expected_machine}, expected_observations} =
      Machine.advance_observed(waiting["machine"], ack)

    assert {{:ok, consumed}, observations} =
             Segment.consume_operation_observed(roundtrip(settled), pending_revision + 2, ack)

    assert observations === expected_observations
    assert consumed["machine"] === expected_machine
    assert consumed["machine"]["pending_request"] == nil
    assert consumed["journal"] === settled["journal"]
    assert consumed["revision"] == pending_revision + 2
    assert consumed["consumed_operations"] == waiting["consumed_operations"] + 1
    assert roundtrip(consumed) === consumed
    %{pending: pending, settled: settled, consumed: consumed, observations: observations}
  end

  defp boundary(snapshot, remaining \\ 10_000)
  defp boundary(_, 0), do: flunk("ordinary state Segment helper exhausted")

  defp boundary(snapshot, remaining) do
    case Segment.advance_observed(snapshot) do
      {{:continue, next}, []} -> boundary(next, remaining - 1)
      {{kind, _, _} = result, []} when kind in [:request, :checkpoint, :complete] -> result
      other -> flunk("unexpected ordinary state Segment transition: #{inspect(other)}")
    end
  end

  defp roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
