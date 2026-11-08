defmodule Synapsis.RoutineRunsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentRun, RoutineRuns}
  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup do
    name = "runs-reader-#{System.unique_integer([:positive])}"

    assert {:ok, agent} =
             Store.put(:agent, %{"id" => Ecto.UUID.generate(), "name" => name, "enabled" => true})

    id = Ecto.UUID.generate()

    for type <- [:routine, :heartbeat] do
      assert {:ok, _} =
               Store.put(type, %{
                 "id" => id,
                 "name" => "Saved #{type}",
                 "enabled" => true,
                 "kind" => "heartbeat",
                 "prompt" => "stored fixture",
                 "schedule" => "0 0 1 1 *",
                 "agent_name" => name
               })
    end

    on_exit(fn ->
      for type <- [:routine, :heartbeat], do: Store.delete(type, id)
      Store.delete(:agent, agent["id"])
    end)

    %{name: name, id: id}
  end

  test "real Concord terminal pages sort finished times and UUID ties, reload and exact source-qualified history",
       ctx do
    at = ~U[2026-10-27 12:00:00.000000Z]
    first = run(ctx, "routine", at, id: "ffffffff-ffff-4fff-8fff-ffffffffffff")
    second = run(ctx, "routine", at, id: "00000000-0000-4000-8000-000000000001")
    third = run(ctx, "routine", DateTime.add(at, -1), status: "failed", error: "fixture failure")
    heartbeat = run(ctx, "heartbeat", DateTime.add(at, 1))
    run(ctx, nil, DateTime.add(at, 2))
    run(ctx, "routine", nil, status: "running")
    assert :ok = Store.reload(:routine)
    assert :ok = Store.reload(:heartbeat)
    assert {:ok, page} = RoutineRuns.page(ctx.name, "routine", ctx.id, limit: 2)
    assert Enum.map(page.runs, & &1.id) == [first.id, second.id]
    assert page.coverage == %{source_attribution: "explicit_only", legacy_history: "unknown"}
    assert page.has_more == true
    assert page.count == 2
    assert {:ok, last} = RoutineRuns.page(ctx.name, "routine", ctx.id, cursor: page.next_cursor)
    assert [%{id: id, status: "failed", error: "fixture failure"}] = last.runs
    assert id == third.id
    assert last.has_more == false
    assert last.next_cursor == nil
    assert {:ok, exact} = RoutineRuns.page(ctx.name, "routine", ctx.id, run_id: first.id)
    assert exact.runs == [hd(page.runs)]
    assert {:ok, other_source} = RoutineRuns.page(ctx.name, "heartbeat", ctx.id)
    assert Enum.map(other_source.runs, & &1.id) == [heartbeat.id]
    assert {:ok, persisted} = Synapsis.AgentRun.Store.fetch(first.id)
    assert persisted == first
  end

  test "public fields are bounded with explicit shortening flags and truthful empty coverage",
       ctx do
    terminal =
      run(ctx, "routine", DateTime.utc_now(),
        summary: String.duplicate("終", 3000),
        provider: String.duplicate("p", 500),
        model: "fixture-model"
      )

    assert {:ok, page} = RoutineRuns.page(ctx.name, "routine", ctx.id)
    assert [entry] = page.runs
    assert entry.id == terminal.id
    assert entry.truncated.summary == true
    assert entry.truncated.provider == true
    assert byte_size(entry.summary) <= 2048
    assert entry.model == "fixture-model"
    assert entry.assistant_name == ctx.name
    assert entry.session_id == terminal.session_id
    assert entry.automation_ref == %{"source" => "routine", "id" => ctx.id}
    assert {:ok, empty} = RoutineRuns.page(ctx.name, "heartbeat", ctx.id)
    assert empty.runs == []
    assert empty.coverage.legacy_history == "unknown"
  end

  defp run(ctx, source, finished, attrs \\ []) do
    run =
      struct!(
        AgentRun,
        Keyword.merge(
          [
            id: Ecto.UUID.generate(),
            kind: "heartbeat",
            source: "scheduler",
            status: "completed",
            assistant_name: ctx.name,
            session_id: Ecto.UUID.generate(),
            routine_id: ctx.id,
            heartbeat_id: ctx.id,
            finished_at: finished,
            started_at: ~U[2026-10-27 11:00:00.000000Z],
            prompt: "private prompt",
            metadata:
              if(source,
                do: %{"automation_ref" => %{"source" => source, "id" => ctx.id}},
                else: %{}
              )
          ],
          attrs
        )
      )

    event = %{
      "event_id" => Ecto.UUID.generate(),
      "run_id" => run.id,
      "sequence" => 0,
      "type" => "fixture"
    }

    assert {:ok, ^run, :committed} = Synapsis.AgentRun.Store.create(run, event)

    on_exit(fn ->
      Concord.Turso.delete("coord/agent_runs/" <> run.id)

      Concord.Turso.delete(
        "coord/agent_run_events/" <> run.id <> "/000000000000-" <> event["event_id"]
      )

      Concord.Turso.delete("coord/agent_run_event_ids/" <> event["event_id"])
    end)

    run
  end
end
