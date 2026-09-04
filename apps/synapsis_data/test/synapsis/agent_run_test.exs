defmodule Synapsis.AgentRunTest do
  use ExUnit.Case, async: true

  alias Synapsis.AgentRun

  test "from_store fills defaults for legacy maps missing new fields" do
    legacy = %{
      id: "run-1",
      kind: "manual",
      status: "running",
      source: "web",
      prompt: "hello",
      tool_profile: "read_only",
      metadata: %{"request_id" => "x"}
    }

    run = AgentRun.from_store(legacy)

    assert run.id == "run-1"
    assert run.status == "running"
    assert run.attempt == 1
    assert run.revision == 0
    assert run.last_event_sequence == 0
    assert run.recovery_state == %{}
    assert run.policy_snapshot == %{}
    assert run.capability_snapshot == %{}
    assert run.metadata == %{"request_id" => "x"}
    refute AgentRun.terminal?(run)
  end

  test "from_store accepts string keys from Concord" do
    run =
      AgentRun.from_store(%{
        "id" => "run-2",
        "kind" => "heartbeat",
        "status" => "queued",
        "source" => "system",
        "prompt" => "pulse",
        "tool_profile" => "heartbeat",
        "revision" => 3,
        "last_event_sequence" => 5
      })

    assert run.revision == 3
    assert run.last_event_sequence == 5
  end

  test "changeset accepts extended statuses and scheduler source" do
    cs =
      AgentRun.changeset(%AgentRun{}, %{
        kind: "schedule",
        status: "starting",
        source: "scheduler",
        prompt: "nightly",
        tool_profile: "read_only",
        idempotency_key: "occ-1",
        attempt: 2
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :status) == "starting"
    assert Ecto.Changeset.get_field(cs, :source) == "scheduler"
  end

  test "changeset rejects unknown status" do
    cs =
      AgentRun.changeset(%AgentRun{}, %{
        kind: "manual",
        status: "bogus",
        source: "web",
        prompt: "x",
        tool_profile: "read_only"
      })

    refute cs.valid?
  end

  test "to_store_map round-trips through from_store" do
    original = %AgentRun{
      id: "run-3",
      kind: "manual",
      status: "unknown_outcome",
      source: "system",
      prompt: "recover",
      tool_profile: "coding",
      attempt: 1,
      revision: 4,
      last_event_sequence: 9,
      policy_snapshot: %{"mode" => "ask"},
      capability_snapshot: %{"profile" => "coding"},
      recovery_state: %{"side_effect_intent" => true},
      idempotency_key: "k1",
      metadata: %{}
    }

    assert AgentRun.terminal?(original)
    assert AgentRun.from_store(AgentRun.to_store_map(original)) == original
  end
end
