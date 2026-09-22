defmodule Synapsis.Agent.RunsAtomicTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.{RunEvents, Runs}
  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.AgentRun

  @attrs %{kind: "manual", source: "web", prompt: "atomic run", tool_profile: "read_only"}

  defmodule FaultStore do
    def get(key, opts) do
      case Process.get(:store_fault) do
        :read -> {:error, :read_unavailable}
        _ -> Concord.Turso.get(key, opts)
      end
    end

    def prefix_scan(prefix, opts) do
      case Process.get(:store_fault) do
        :scan -> {:error, :scan_unavailable}
        _ -> Concord.Turso.prefix_scan(prefix, opts)
      end
    end

    def txn(spec, opts) do
      if owner = Process.get(:txn_barrier) do
        send(owner, {:transaction_ready, self()})

        receive do
          :commit -> :ok
        after
          1_000 -> raise "transaction barrier timed out"
        end
      end

      case Process.get(:store_fault) do
        :before_commit ->
          {:error, :write_unavailable}

        fault when fault in [:lost_reply, :lost_reply_and_read] ->
          {:ok, %{succeeded: true}} = Concord.Turso.txn(spec, opts)
          Process.put(:store_fault, if(fault == :lost_reply_and_read, do: :read, else: nil))
          {:error, :timeout}

        _ ->
          Concord.Turso.txn(spec, opts)
      end
    end
  end

  setup do
    previous = Application.get_env(:synapsis_data, :agent_run_store_adapter)
    Application.put_env(:synapsis_data, :agent_run_store_adapter, FaultStore)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_data, :agent_run_store_adapter, previous),
        else: Application.delete_env(:synapsis_data, :agent_run_store_adapter)
    end)

    :ok
  end

  test "a stale cancellation cannot overwrite completion or append a losing event" do
    run = running()
    assert {:ok, completed} = Runs.mark_completed(run, "done")
    events = RunEvents.list_for_run(run.id)
    id = Ecto.UUID.generate()
    assert {:error, :stale_run} = Runs.mark_cancelled(run, %{event_id: id})
    assert Runs.get(run.id) == completed
    assert RunEvents.list_for_run(run.id) == events
    assert RunEvents.get_by_event_id(id) == nil
  end

  test "simultaneous terminal transitions commit only one event and projection" do
    run = running()
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    tasks =
      for status <- [:complete, :cancel] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(:txn_barrier, owner)

          receive do
            :go ->
              if status == :complete,
                do: Runs.mark_completed(run, "winner"),
                else: Runs.mark_cancelled(run)
          after
            1_000 -> flunk("race fixture timed out")
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    assert_receive {:transaction_ready, first}, 1_000
    assert_receive {:transaction_ready, second}, 1_000
    send(first, :commit)
    send(second, :commit)
    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :stale_run}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Runs.get(run.id) == winner

    assert [terminal] =
             Enum.filter(
               RunEvents.list_for_run(run.id),
               &(&1["sequence"] == winner.last_event_sequence)
             )

    assert terminal["type"] == "run." <> winner.status
    assert [_] = Synapsis.AgentEvents.list(work_id: run.id, event_type: terminal["type"])
  end

  test "transaction failure leaves projection, event, and index unchanged" do
    run = running()
    events = RunEvents.list_for_run(run.id)
    observations = Synapsis.AgentEvents.list(work_id: run.id)
    id = Ecto.UUID.generate()
    Process.put(:store_fault, :before_commit)
    assert {:error, :write_unavailable} = Runs.mark_completed(run, "done", %{event_id: id})
    Process.delete(:store_fault)
    assert Runs.get(run.id) == run
    assert RunEvents.list_for_run(run.id) == events
    assert RunEvents.get_by_event_id(id) == nil
    assert Synapsis.AgentEvents.list(work_id: run.id) == observations
  end

  test "a committed transaction with a lost reply is reconciled without another revision" do
    run = running()
    id = Ecto.UUID.generate()
    Process.put(:store_fault, :lost_reply)

    assert {:ok, completed} =
             Runs.mark_completed(run, "done", %{event_id: id, metadata: %{"a" => 1}})

    assert completed.metadata == %{"a" => 1}

    assert {:ok, ^completed} =
             Runs.mark_completed(run, "done", %{event_id: id, metadata: %{"a" => 1}})

    assert {:ok, ^completed} =
             Runs.mark_completed(completed, "done", %{event_id: id, metadata: %{"a" => 1}})

    assert completed.revision == run.revision + 1
    assert Enum.count(RunEvents.list_for_run(run.id), &(&1["event_id"] == id)) == 1
  end

  test "failed readback reports uncertainty and a later exact retry finds the committed result" do
    run = running()
    id = Ecto.UUID.generate()
    Process.put(:store_fault, :lost_reply_and_read)
    assert {:error, _} = Runs.mark_completed(run, "done", %{event_id: id})
    Process.delete(:store_fault)
    assert {:ok, completed} = Runs.mark_completed(run, "done", %{event_id: id})
    assert completed.revision == run.revision + 1
    assert Runs.get(run.id) == completed
  end

  test "event IDs reject different payloads, attributes, types, and runs" do
    run = running()
    id = Ecto.UUID.generate()

    assert {:ok, completed} =
             Runs.mark_completed(run, "done", %{event_id: id, metadata: %{"a" => 1}})

    for {summary, attrs} <- [
          {"changed", %{metadata: %{"a" => 1}}},
          {"done", %{metadata: %{"a" => 2}}}
        ] do
      assert {:error, :event_id_conflict} =
               Runs.mark_completed(run, summary, Map.put(attrs, :event_id, id))
    end

    assert {:error, :event_id_conflict} = Runs.mark_cancelled(run, %{event_id: id})
    assert {:error, :event_id_conflict} = Runs.mark_completed(running(), "done", %{event_id: id})
    assert Runs.get(run.id) == completed
  end

  test "multi-step convenience transitions reserve retry identity for the requested event" do
    for transition <- [&Runs.mark_running/2, &Runs.mark_waiting_approval/2] do
      assert {:ok, queued} = Runs.create(@attrs)
      id = Ecto.UUID.generate()
      assert {:ok, updated} = transition.(queued, %{"event_id" => id})
      assert {:ok, ^updated} = transition.(queued, %{"event_id" => id})
      assert updated.status in ["running", "waiting_approval"]
      assert Enum.count(RunEvents.list_for_run(queued.id), &(&1["event_id"] == id)) == 1
    end
  end

  test "typed event retry is exact including sequence and timestamp" do
    run = running()

    event =
      RunEvent.new("run.completed",
        run_id: run.id,
        sequence: run.last_event_sequence + 1,
        payload: %{"summary" => "done"}
      )

    assert {:ok, completed} = Runs.apply_event(run, event)
    assert {:ok, ^completed} = Runs.apply_event(run, event)
    assert [observation] = Synapsis.AgentEvents.list(work_id: run.id, event_type: "run.completed")
    assert observation.payload["status"] == "completed"

    assert {:error, :event_id_conflict} =
             Runs.apply_event(run, %{event | sequence: event.sequence + 1})

    assert {:error, :event_id_conflict} =
             Runs.apply_event(run, %{event | occurred_at: DateTime.add(event.occurred_at, 1)})

    assert {:error, :run_id_mismatch} = Runs.apply_event(running(), event)
  end

  test "simultaneous retries of the same typed event return one durable result" do
    run = running()
    event = RunEvent.new("run.completed", run_id: run.id, sequence: run.last_event_sequence + 1)
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(:txn_barrier, owner)
          Runs.apply_event(run, event)
        end)
      end

    assert_receive {:transaction_ready, first}, 1_000
    assert_receive {:transaction_ready, second}, 1_000
    send(first, :commit)
    send(second, :commit)
    assert [{:ok, completed}, {:ok, duplicate}] = Enum.map(tasks, &Task.await(&1, 2_000))
    assert completed == duplicate
    assert completed.revision == run.revision + 1
  end

  test "a retry remains idempotent after the reducer's recent event cache is exhausted" do
    run = running()
    id = Ecto.UUID.generate()
    assert {:ok, first} = Runs.mark_side_effect_intent(run, %{event_id: id})

    current =
      Enum.reduce(1..70, first, fn _, state ->
        {:ok, updated} = Runs.mark_side_effect_intent(state)
        updated
      end)

    assert length(current.recovery_state["applied_event_ids"]) == 64
    assert {:ok, ^current} = Runs.mark_side_effect_intent(run, %{event_id: id})
  end

  test "public raw persistence and standalone critical append cannot bypass lifecycle checks" do
    run = running()
    assert {:ok, ^run} = Runs.persist(run)
    assert {:error, :lifecycle_event_required} = Runs.persist(%{run | status: "completed"})
    event = RunEvent.new("run.completed", run_id: run.id, sequence: run.last_event_sequence + 1)
    assert {:ok, ^event} = RunEvents.append_critical(run, event)
    assert Runs.get(run.id).status == "completed"
    assert {:error, :lifecycle_event_required} = Runs.persist(run)
  end

  test "read and scan failures stay distinct from absence" do
    assert :not_found = Runs.fetch(Ecto.UUID.generate())
    Process.put(:store_fault, :read)
    assert {:error, :read_unavailable} = Runs.fetch(Ecto.UUID.generate())

    assert {:error, :read_unavailable} =
             Runs.create(Map.put(@attrs, :idempotency_key, Ecto.UUID.generate()))

    Process.put(:store_fault, :scan)
    assert {:error, :scan_unavailable} = Runs.list_by_status_result("queued")
  end

  test "creation failure leaves neither a run nor an idempotency index" do
    id = Ecto.UUID.generate()
    key = Ecto.UUID.generate()
    Process.put(:store_fault, :before_commit)

    assert {:error, :write_unavailable} =
             Runs.create(Map.merge(@attrs, %{id: id, idempotency_key: key}))

    Process.delete(:store_fault)
    assert :not_found = Runs.fetch(id)
    assert Runs.get_by_idempotency_key(key) == nil
    assert RunEvents.list_for_run(id) == []
  end

  test "concurrent creation with one idempotency key has one durable identity" do
    attrs = Map.put(@attrs, :idempotency_key, Ecto.UUID.generate())
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()
    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    tasks =
      for id <- ids do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(:txn_barrier, owner)
          Runs.create(Map.put(attrs, :id, id))
        end)
      end

    assert_receive {:transaction_ready, first_task}, 1_000
    assert_receive {:transaction_ready, second_task}, 1_000
    send(first_task, :commit)
    send(second_task, :commit)

    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await(&1, 2_000))
    assert first.id == second.id
    assert [%{"type" => "run.created"}] = RunEvents.list_for_run(first.id)
    [unused_id] = ids -- [first.id]
    assert :not_found = Runs.fetch(unused_id)
    assert RunEvents.list_for_run(unused_id) == []
  end

  test "non-queued creation stores its initial state with its creation fact" do
    assert {:ok, run} =
             Runs.create(Map.merge(@attrs, %{status: "completed", summary: "imported"}))

    assert run.status == "completed"
    assert run.summary == "imported"
    assert [%{"payload" => %{"initial_status" => "completed"}}] = RunEvents.list_for_run(run.id)
    assert {:error, _} = Runs.create(Map.put(@attrs, :status, "invalid"))
  end

  test "legacy string-keyed compressed snapshots are fenced and normalized" do
    run = running()

    legacy =
      run
      |> AgentRun.to_store_map()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    assert :ok =
             Concord.Turso.put(
               "coord/agent_runs/" <> run.id,
               Concord.Compression.compress(legacy, force: true)
             )

    assert {:ok, current} = Runs.fetch(run.id)
    assert {:ok, completed} = Runs.mark_completed(current, "done")
    assert {:error, :stale_run} = Runs.mark_cancelled(current)
    assert Runs.get(run.id) == completed
  end

  test "legacy partial critical records fail closed instead of reporting a committed transition" do
    run = running()
    event = RunEvent.new("run.completed", run_id: run.id, sequence: run.last_event_sequence + 1)

    assert :ok =
             Concord.Turso.put("coord/agent_run_event_ids/" <> event.event_id, %{
               "run_id" => run.id,
               "sequence" => event.sequence,
               "type" => event.type
             })

    assert {:error, :incomplete_event} = Runs.apply_event(run, event)
    assert Runs.get(run.id) == run
  end

  test "legacy snapshots with missing revision fields can transition without losing defaults" do
    id = Ecto.UUID.generate()
    legacy = Map.merge(@attrs, %{id: id, inserted_at: DateTime.utc_now()})
    assert :ok = Concord.Turso.put("coord/agent_runs/" <> id, legacy)
    assert {:ok, run} = Runs.fetch(id)
    assert run.revision == 0
    assert {:ok, started} = Runs.mark_starting(run)
    assert started.revision == 1
    assert started.status == "starting"
  end

  test "dangling idempotency indexes are not treated as absent" do
    key = Ecto.UUID.generate()

    assert :ok =
             Concord.Turso.put("coord/agent_run_idempotency/" <> key, %{
               "run_id" => Ecto.UUID.generate()
             })

    assert {:error, :incomplete_idempotency} = Runs.create(Map.put(@attrs, :idempotency_key, key))
  end

  test "an event without its index cannot be overwritten or counted as committed" do
    run = running()
    event = RunEvent.new("run.completed", run_id: run.id, sequence: run.last_event_sequence + 1)
    sequence = event.sequence |> Integer.to_string() |> String.pad_leading(12, "0")
    key = "coord/agent_run_events/" <> run.id <> "/" <> sequence <> "-" <> event.event_id
    assert :ok = Concord.Turso.put(key, RunEvent.to_map(event))
    assert {:error, :incomplete_event} = Runs.apply_event(run, event)
    assert {:error, :incomplete_event} = Runs.mark_completed(run, "a different event ID")
    assert Runs.get(run.id) == run
  end

  defp running do
    {:ok, run} = Runs.create(@attrs)
    {:ok, run} = Runs.mark_running(run)
    run
  end
end
