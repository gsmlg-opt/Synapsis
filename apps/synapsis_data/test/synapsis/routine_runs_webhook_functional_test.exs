defmodule Synapsis.RoutineRunsWebhookFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentRun, RoutineRuns}
  alias Synapsis.Config.Store

  setup do
    name = "webhook-history-#{System.unique_integer([:positive])}"
    id = Ecto.UUID.generate()

    assert {:ok, agent} =
             Store.put(:agent, %{"id" => Ecto.UUID.generate(), "name" => name, "enabled" => true})

    for source <- [:routine, :heartbeat] do
      assert {:ok, _} =
               Store.put(source, %{
                 "id" => id,
                 "name" => "Webhook #{source}",
                 "enabled" => true,
                 "kind" => "heartbeat",
                 "prompt" => "Webhook history fixture",
                 "schedule" => "0 0 1 1 *",
                 "agent_name" => name
               })
    end

    on_exit(fn ->
      for source <- [:routine, :heartbeat], do: Store.delete(source, id)
      Store.delete(:agent, agent["id"])
    end)

    %{name: name, id: id}
  end

  test "Concord history exposes the settled primary delivery and completion separately from execution",
       ctx do
    target = "http://localhost:45001/finished"

    delivery = %{
      "mode" => "webhook",
      "status" => "delivered",
      "delivered" => true,
      "attempted" => true,
      "http_status" => 204,
      "attempt_count" => 1,
      "intended" => %{"to" => target, "source" => "explicit"},
      "resolved" => %{"to" => target, "source" => "explicit", "ok" => true}
    }

    run = persist(ctx, "routine", delivery, "Webhook output\nexact bytes  ")
    assert :ok = Store.reload(:routine)
    assert {:ok, page} = RoutineRuns.page(ctx.name, "routine", ctx.id, run_id: run.id)
    assert [entry] = page.runs
    assert entry.id == run.id
    assert entry.status == "completed"
    assert entry.summary == run.summary
    assert entry.automation_completion_status == "succeeded"
    assert entry.automation_delivery == delivery
    assert entry.automation_ref == %{"source" => "routine", "id" => ctx.id}
    assert byte_size(Jason.encode!(page)) <= 65_536
    assert {:ok, ^run} = Synapsis.AgentRun.Store.fetch(run.id)
    assert {:ok, other} = RoutineRuns.page(ctx.name, "heartbeat", ctx.id)
    assert other.runs == []
  end

  test "intentional empty success remains a successful completion with zero delivery attempts",
       ctx do
    delivery = %{
      "mode" => "webhook",
      "status" => "not-delivered",
      "delivered" => false,
      "attempted" => false,
      "suppression_reason" => "empty"
    }

    run = persist(ctx, "heartbeat", delivery, "")
    assert :ok = Store.reload(:heartbeat)
    assert {:ok, page} = RoutineRuns.page(ctx.name, "heartbeat", ctx.id)
    assert [entry] = page.runs
    assert entry.id == run.id
    assert entry.status == "completed"
    assert entry.summary == ""
    assert entry.automation_completion_status == "succeeded"
    assert entry.automation_delivery == delivery
    assert entry.automation_ref == %{"source" => "heartbeat", "id" => ctx.id}
    assert {:ok, ^run} = Synapsis.AgentRun.Store.fetch(run.id)
  end

  defp persist(ctx, source, delivery, summary) do
    run = %AgentRun{
      id: Ecto.UUID.generate(),
      kind: "heartbeat",
      source: "scheduler",
      status: "completed",
      assistant_name: ctx.name,
      session_id: Ecto.UUID.generate(),
      routine_id: ctx.id,
      heartbeat_id: ctx.id,
      started_at: ~U[2026-10-28 01:00:00.000000Z],
      finished_at: ~U[2026-10-28 01:00:01.000000Z],
      prompt: "Webhook history fixture",
      summary: summary,
      metadata: %{
        "automation_ref" => %{"source" => source, "id" => ctx.id},
        "automation_job" => %{"prompt" => "Frozen authored prompt"},
        "automation_delivery" => delivery,
        "automation_completion_status" => "succeeded"
      }
    }

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
