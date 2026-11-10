defmodule Synapsis.Agent.Runtime.GoalStoreFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Goal.State
  alias Backplane.AgentRuntime.Goal.Store, as: NativeStore
  alias Synapsis.Agent.Runtime.GoalStore
  alias Synapsis.Goal.Store, as: DataStore

  setup do
    :ok = Synapsis.Session.Store.ensure_started()
    thread = Ecto.UUID.generate()
    other_thread = Ecto.UUID.generate()
    marker_key = "coord/goals/functional-tests/" <> Ecto.UUID.generate()

    on_exit(fn ->
      for key <- [goal_key(thread), goal_key(other_thread), marker_key] do
        assert :ok = Concord.Turso.delete(key, timeout: 5_000)
      end
    end)

    %{thread: thread, other_thread: other_thread, marker_key: marker_key}
  end

  test "initialization commits the canonical complete empty thread record", %{thread: thread} do
    expected = empty_record(thread)
    assert :not_found = DataStore.load(thread)
    assert {:ok, ^expected} = State.new(thread, [])
    assert {:ok, ^expected} = NativeStore.load(GoalStore, :local, thread)

    committed = %{expected | revision: 1}

    assert {:ok, ^committed} =
             NativeStore.compare_and_swap(GoalStore, :local, thread, 0, nil, expected)

    assert {:ok, ^committed} = DataStore.load(thread)
    assert {:ok, ^committed} = NativeStore.load(GoalStore, :local, thread)
    metadata = stored_record(thread, committed)
    assert metadata.version == 1
    assert metadata.create_revision == metadata.mod_revision
  end

  test "create and update preserve Unicode and the full native receipt snapshot", %{
    thread: thread,
    marker_key: marker_key
  } do
    # A separate owned write makes storage revision differ from Goal revision.
    assert :ok = Concord.Turso.put(marker_key, %{purpose: "storage revision separation"})
    {created, expected_created} = goal_record(thread, "核验完整快照 🌙", 400)
    committed_created = %{expected_created | revision: 1}

    assert created.revision == 0

    assert {:ok, ^committed_created} =
             NativeStore.compare_and_swap(GoalStore, :local, thread, 0, nil, created)

    first_metadata = stored_record(thread, committed_created)
    assert first_metadata.mod_revision > committed_created.revision

    {accounted, expected_accounted} = started_turn(committed_created)
    assert {:ok, updated} = State.update(accounted, :host, %{objective: "保留收据与私有围栏 ✅"})

    expected_goal = %{
      expected_accounted.goal
      | objective: "保留收据与私有围栏 ✅",
        updated_at_ms: updated.goal.updated_at_ms
    }

    expected_updated = %{expected_accounted | goal: expected_goal, revision: 2}
    assert updated === %{expected_updated | revision: 1}

    assert {:ok, ^expected_updated} =
             NativeStore.compare_and_swap(
               GoalStore,
               :local,
               thread,
               1,
               committed_created.goal.goal_id,
               updated
             )

    second_metadata = stored_record(thread, expected_updated)
    assert second_metadata.create_revision == first_metadata.create_revision
    assert second_metadata.mod_revision > first_metadata.mod_revision
    assert second_metadata.version == 2
    assert {:ok, ^expected_updated} = DataStore.load(thread)
    assert {:ok, ^expected_updated} = fresh_load(thread)
  end

  test "clear retains the full tombstone and replacement advances within one thread", %{
    thread: thread,
    other_thread: other_thread
  } do
    {created, expected_created} = goal_record(thread, "保存清除历史", nil)
    {accounted, expected_accounted} = started_turn(created)
    committed = %{expected_accounted | revision: 1}

    assert {:ok, ^committed} =
             NativeStore.compare_and_swap(GoalStore, :local, thread, 0, nil, accounted)

    first_metadata = stored_record(thread, committed)
    assert {:ok, cleared} = State.clear(committed)

    tombstone = %{
      expected_accounted
      | revision: 2,
        goal: nil,
        turns: %{},
        continuation_deferral: %{reason: :cleared}
    }

    assert cleared === %{tombstone | revision: 1}

    assert {:ok, ^tombstone} =
             NativeStore.compare_and_swap(
               GoalStore,
               :local,
               thread,
               1,
               expected_created.goal.goal_id,
               cleared
             )

    cleared_metadata = stored_record(thread, tombstone)
    assert cleared_metadata.version == 2
    assert cleared_metadata.create_revision == first_metadata.create_revision
    assert cleared_metadata.mod_revision > first_metadata.mod_revision
    assert {:ok, ^tombstone} = fresh_load(thread)

    assert {:ok, replacement} = State.create(tombstone, %{objective: "新的目标 🚀"})
    replacement_goal = checked_goal(replacement.goal, thread, "新的目标 🚀", nil)

    expected_replacement = %{
      tombstone
      | revision: 3,
        goal: replacement_goal,
        baselines: %{},
        continuation_deferral: nil
    }

    assert replacement === %{expected_replacement | revision: 2}
    refute replacement_goal.goal_id == expected_created.goal.goal_id

    assert {:ok, ^expected_replacement} =
             NativeStore.compare_and_swap(GoalStore, :local, thread, 2, nil, replacement)

    replacement_metadata = stored_record(thread, expected_replacement)
    assert replacement_metadata.version == 3
    assert replacement_metadata.create_revision == first_metadata.create_revision
    assert replacement_metadata.mod_revision > cleared_metadata.mod_revision
    assert {:ok, ^expected_replacement} = fresh_load(thread)

    {other, expected_other} = goal_record(other_thread, "独立会话", 100)
    committed_other = %{expected_other | revision: 1}

    assert {:ok, ^committed_other} =
             NativeStore.compare_and_swap(GoalStore, :local, other_thread, 0, nil, other)

    stored_record(other_thread, committed_other)
    assert {:ok, ^committed_other} = fresh_load(other_thread)
    assert {:ok, ^expected_replacement} = fresh_load(thread)
  end

  defp goal_record(thread, objective, budget) do
    expected = empty_record(thread)
    assert {:ok, initial} = State.new(thread, [])
    assert {:ok, created} = State.create(initial, %{objective: objective, token_budget: budget})
    goal = checked_goal(created.goal, thread, objective, budget)
    expected_created = %{expected | goal: goal}
    assert created === expected_created
    {created, expected_created}
  end

  defp checked_goal(goal, thread, objective, budget) do
    assert is_binary(goal.goal_id) and byte_size(goal.goal_id) == 32
    assert is_integer(goal.created_at_ms) and goal.created_at_ms > 0

    expected = %{
      thread_id: thread,
      goal_id: goal.goal_id,
      objective: objective,
      status: :active,
      token_budget: budget,
      tokens_used: 0,
      time_used_seconds: 0,
      created_at_ms: goal.created_at_ms,
      updated_at_ms: goal.created_at_ms
    }

    assert goal === expected
    expected
  end

  defp started_turn(state) do
    run = Ecto.UUID.generate()
    turn = Ecto.UUID.generate()
    receipt_id = Ecto.UUID.generate()
    attempt = Ecto.UUID.generate()
    baseline = %{attempt_id: attempt, input_tokens: 7, cached_tokens: 2, output_tokens: 3}

    receipt = %{
      receipt_id: receipt_id,
      thread_id: state.thread_id,
      expected_goal_id: state.goal.goal_id,
      run_id: run,
      incarnation: 1,
      turn_id: turn,
      revision: 1,
      type: :turn_started,
      payload: %{mode: :execution, usage_baseline: baseline}
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(receipt)) |> Base.encode16()

    expected = %{
      state
      | receipts: %{receipt_id => digest},
        runtime_receipt_counts: %{{run, 1} => 1},
        event_revisions: %{{run, 1} => 1},
        baselines: %{{run, 1, attempt} => Map.delete(baseline, :attempt_id)},
        turns: %{
          {run, 1, turn} => %{
            mode: :execution,
            automatic: false,
            activity: false,
            empty_final: false,
            failed_exec: false,
            success: false
          }
        }
    }

    assert {:ok, accounted} = State.account(state, receipt)
    assert accounted === expected
    {accounted, expected}
  end

  defp stored_record(thread, expected) do
    assert {:ok, %Concord.KV.Record{value: ^expected} = metadata} =
             Concord.KV.get(goal_key(thread), engine: :turso, metadata: true, timeout: 5_000)

    assert is_integer(metadata.mod_revision) and metadata.mod_revision > 0
    metadata
  end

  defp fresh_load(thread) do
    Task.async(fn -> NativeStore.load(GoalStore, :local, thread) end) |> Task.await(10_000)
  end

  defp goal_key(thread), do: "coord/goals/threads/" <> thread

  defp empty_record(thread) do
    %{
      thread_id: thread,
      revision: 0,
      goal: nil,
      receipts: %{},
      runtime_receipt_counts: %{},
      admission_settlements: %{},
      invocations: %{},
      deliveries: %{},
      continuation_deferral: nil,
      interrupted_turn: nil,
      accounting_uncertain: false,
      usage: %{
        reports: %{},
        totals: %{input_tokens: 0, output_tokens: 0, cached_tokens: 0, reasoning_tokens: 0},
        occupancy: %{}
      },
      baselines: %{},
      usage_baselines: %{},
      usage_snapshots: %{},
      turns: %{},
      event_revisions: %{},
      failure_turns: 0,
      empty_turns: 0,
      budget_steering_sent: false,
      max_goal_token_budget: nil
    }
  end
end
