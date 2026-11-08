defmodule Synapsis.Workflow.ContinuationsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.Continuations

  setup do
    %{session_id: Ecto.UUID.generate(), agent_id: Ecto.UUID.generate()}
  end

  test "ordinary workflow snapshots survive each committed checkpoint and completion", %{
    session_id: session_id,
    agent_id: agent_id
  } do
    # These are caller-owned JSON fixtures, not evidence of native execution.
    source = %{
      "kind" => "file",
      "path" => "workflows/问候.json",
      "provenance" => %{"reference" => "fixture:workflow-source", "version" => "v1"},
      "document" => %{"name" => "问候", "args" => %{"language" => "中文"}}
    }

    first_segment = %{
      "occurrence" => "fixture:native-segment-1",
      "source" => source,
      "result_locator" => nil
    }

    before_effect = %{
      "state" => "running",
      "position" => %{"stage" => 0},
      "source" => source,
      "segments" => [first_segment],
      "intended_effect" => %{
        "native_locator" => "fixture:native-segment-1/effect-1",
        "input" => %{"text" => "你好，世界 🌍", "enabled" => true}
      },
      "completed_results" => []
    }

    assert {:ok, created} = Continuations.create(session_id, agent_id, before_effect)
    assert_record(created, session_id, agent_id, before_effect, 1)
    assert {:ok, ^created} = Continuations.load(session_id, created.id)

    ordinary_result = %{
      "native_locator" => "fixture:native-segment-1/effect-1",
      "committed_result_locator" => "fixture:native-segment-1/result-1",
      "output" => [%{"text" => "你好，世界 🌍", "count" => 1, "ratio" => 1.25}]
    }

    after_effect = %{
      "state" => "running",
      "position" => %{"stage" => 1},
      "source" => source,
      "segments" => [first_segment],
      "completed_results" => [ordinary_result]
    }

    after_effect_record = assert_commit(created, after_effect)

    checkpoint = %{
      "kind" => "input",
      "resume" => "same_stage",
      "stage" => 1,
      "commandInput" => %{"prompt" => "选择下一项", "previous" => ordinary_result["output"]},
      "items" => [%{"id" => "a", "label" => "继续", "default" => false}],
      "schema" => %{"type" => "object", "properties" => %{"choice" => %{"type" => "string"}}}
    }

    needs_input =
      after_effect
      |> Map.put("state", "needs_input")
      |> Map.put("checkpoint", checkpoint)

    waiting_record = assert_commit(after_effect_record, needs_input)

    next_source = put_in(source, ["provenance", "version"], "v2")

    next_segment = %{
      "occurrence" => "fixture:native-segment-2",
      "source" => next_source,
      "result_locator" => nil
    }

    resumed = %{
      "state" => "running",
      "position" => %{"stage" => 1, "resume" => "same_stage"},
      "source" => next_source,
      "segments" => [first_segment, next_segment],
      "completed_results" => [ordinary_result],
      "response_claim" => %{
        "checkpoint_revision" => waiting_record.revision,
        "responseJson" => %{"choice" => "a", "note" => "已确认", "optional" => nil},
        "next_native_locator" => next_segment["occurrence"]
      },
      "commandInput" => checkpoint["commandInput"],
      "items" => checkpoint["items"]
    }

    resumed_record = assert_commit(waiting_record, resumed)

    completed = %{
      "state" => "completed",
      "position" => %{"stage" => 2},
      "source" => next_source,
      "segments" => [
        first_segment,
        %{next_segment | "result_locator" => "fixture:native-segment-2/result-2"}
      ],
      "completed_results" => [ordinary_result],
      "output" => %{
        "message" => "完成 ✓",
        "items" => [nil, true, false, 7, 2.5, ["nested", %{"保留" => "原样"}]],
        "metadata" => %{}
      }
    }

    completed_record = assert_commit(resumed_record, completed)
    assert completed_record.revision == 5
    assert completed_record.snapshot["segments"] == completed["segments"]
    assert completed_record.snapshot["completed_results"] == [ordinary_result]
  end

  test "a fresh task loads the record after its creating and updating task exits normally", %{
    session_id: session_id,
    agent_id: agent_id
  } do
    caller = self()
    initial = %{"state" => "running", "completed_results" => []}
    completed = %{"state" => "completed", "output" => ["独立读取", %{"value" => 3.5}]}

    writer =
      Task.async(fn ->
        send(caller, {:writer_ready, self()})

        receive do
          :write ->
            assert {:ok, created} = Continuations.create(session_id, agent_id, initial)
            assert {:ok, ^created} = Continuations.load(session_id, created.id)
            assert_commit(created, completed)
        after
          5_000 -> flunk("writer did not receive its start message")
        end
      end)

    assert_receive {:writer_ready, writer_pid}, 5_000
    writer_monitor = Process.monitor(writer_pid)
    send(writer_pid, :write)
    updated = Task.await(writer, 10_000)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer_pid, :normal}, 5_000

    reader = Task.async(fn -> Continuations.load(session_id, updated.id) end)
    assert {:ok, ^updated} = Task.await(reader, 10_000)
    assert_record(updated, session_id, agent_id, completed, 2)
  end

  test "independent workflows retain distinct identities and their own successful revisions", %{
    session_id: session_id,
    agent_id: agent_id
  } do
    first_snapshot = %{"name" => "first", "state" => "running", "output" => []}
    second_snapshot = %{"name" => "second", "state" => "running", "output" => []}

    assert {:ok, first} = Continuations.create(session_id, agent_id, first_snapshot)
    assert {:ok, second} = Continuations.create(session_id, agent_id, second_snapshot)
    assert_record(first, session_id, agent_id, first_snapshot, 1)
    assert_record(second, session_id, agent_id, second_snapshot, 1)
    assert first.id != second.id
    assert {:ok, ^first} = Continuations.load(session_id, first.id)
    assert {:ok, ^second} = Continuations.load(session_id, second.id)

    first_done = assert_commit(first, %{"state" => "completed", "output" => ["first result"]})

    second_waiting =
      assert_commit(second, %{
        "state" => "needs_input",
        "checkpoint" => %{"prompt" => "继续?", "items" => ["yes", "later"]}
      })

    assert {:ok, ^first_done} = Continuations.load(session_id, first.id)
    assert {:ok, ^second_waiting} = Continuations.load(session_id, second.id)

    second_done =
      assert_commit(second_waiting, %{"state" => "completed", "output" => ["second result"]})

    assert {:ok, ^first_done} = Continuations.load(session_id, first.id)
    assert {:ok, ^second_done} = Continuations.load(session_id, second.id)
    assert first_done.revision == 2
    assert second_done.revision == 3
  end

  defp assert_commit(previous, snapshot) do
    assert {:ok, updated} =
             Continuations.commit(previous.session_id, previous.id, previous.revision, snapshot)

    assert_record(
      updated,
      previous.session_id,
      previous.agent_id,
      snapshot,
      previous.revision + 1
    )

    immutable_fields = [:schema_version, :id, :session_id, :agent_id, :inserted_at]
    assert Map.take(updated, immutable_fields) == Map.take(previous, immutable_fields)
    assert {:ok, ^updated} = Continuations.load(previous.session_id, previous.id)
    updated
  end

  defp assert_record(record, session_id, agent_id, snapshot, revision) do
    assert %{
             schema_version: 1,
             id: id,
             session_id: ^session_id,
             agent_id: ^agent_id,
             revision: ^revision,
             inserted_at: inserted_at,
             updated_at: updated_at,
             snapshot: persisted_snapshot
           } = record

    assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    assert persisted_snapshot === snapshot
    assert {:ok, inserted, _offset} = DateTime.from_iso8601(inserted_at)
    assert {:ok, updated, _offset} = DateTime.from_iso8601(updated_at)
    assert DateTime.compare(updated, inserted) in [:eq, :gt]
  end
end
