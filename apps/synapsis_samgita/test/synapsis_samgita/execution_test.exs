defmodule SynapsisSamgita.ExecutionTest do
  use ExUnit.Case, async: false
  alias Synapsis.Samgita.Executions
  alias SynapsisSamgita.Execution.Worker

  defmodule API do
    def get_task(_, _, id),
      do:
        {:ok,
         %{
           "id" => id,
           "version" => 1,
           "state" => "open",
           "assignee_agent_id" => "agent-1",
           "title" => "Do the selected task"
         }}

    def create_session(_, _, _, opts), do: action(:session, opts, %{"id" => "session-1"})

    def claim(_, _, _, _, _, opts),
      do: action(:claim, opts, %{"id" => "attempt-1", "version" => 1})

    def proof(_, _, _), do: {:ok, "secret-owner-proof"}

    def start(_, _, _, _, _, opts),
      do: action(:start, opts, %{"id" => "attempt-1", "version" => 2})

    def progress(_, _, _, _, _, _, opts) do
      if test = Process.get(:test), do: send(test, {:progress_started, self()})
      action(:progress, opts, %{"version" => 3})
    end

    def report(_, _, _, _, _, outcome, resolved, result, opts) do
      journal =
        Enum.find(Executions.list(), &(&1["commands"]["report"] == opts[:command_id]))

      action(
        :report,
        Keyword.merge(opts,
          outcome: outcome,
          resolved: resolved,
          result: result,
          journal: journal["report"]
        ),
        %{"version" => 4, "state" => outcome}
      )
    end

    defp action(name, opts, result) do
      Process.put(:calls, Process.get(:calls, []) ++ [{name, opts}])

      if Process.get(:fail_action) == name,
        do: {:error, %{status: nil, code: "transport_error", detail: nil}},
        else: {:ok, result}
    end
  end

  defmodule Runtime do
    def prepare(device, _task) do
      Process.put(:selected, {device["implementation"], device["source_id"]})
      {:ok, %{"thread_id" => "thread-1"}}
    end

    def start(handle, _text) do
      Process.put(:runtime_started, true)
      if Process.get(:finish, true), do: send(self(), Process.get(:terminal, :finished))
      {:ok, Map.put(handle, "turn_id", "turn-1")}
    end

    def cancel(_), do: :ok
    def observe(_, :finished), do: {:done, "succeeded", true}
    def observe(_, :failed), do: {:done, "failed", false}
    def observe(_, _), do: :pending
  end

  defmodule OwnerRuntime do
    def prepare(device, _), do: {:ok, %{"actor_id" => device["actor_id"]}}

    def start(%{"actor_id" => id} = handle, _) do
      {actor, test} = :persistent_term.get({__MODULE__, id})
      send(actor, {:start, test})
      {:ok, handle}
    end

    def observe(_, _), do: :pending

    def cancel(%{"actor_id" => id}) do
      {actor, test} = :persistent_term.get({__MODULE__, id})
      send(actor, {:cancel, test})
      :ok
    end
  end

  # Launch is controlled; evidence handling is the production Runtime. The
  # session fixture serves the exact snapshot API read by that Runtime.
  defmodule EvidenceRuntime do
    alias SynapsisSamgita.Execution.Runtime
    def prepare(_, _), do: {:ok, Process.get(:evidence_handle)}

    def start(handle, _) do
      for event <- Process.get(:evidence_events), do: send(self(), event)
      {:ok, handle}
    end

    defdelegate observe(handle, event), to: Runtime
    defdelegate capture(handle, event), to: Runtime
    def cancel(_), do: :ok
  end

  defmodule SnapshotSession do
    use GenServer

    def start_link(snapshot),
      do:
        GenServer.start_link(__MODULE__, snapshot,
          name: {:via, Registry, {Synapsis.Session.Registry, snapshot.session.id}}
        )

    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_cast(:cancel, snapshot), do: {:noreply, snapshot}
  end

  setup do
    clear_executions!()
    on_exit(&clear_executions!/0)
    :ok
  end

  # These tests leave more than a generic delete_many batch, and owner-loss
  # cleanup may still be retiring a guard. Wait for that work, then remove the
  # entire owned prefix atomically and prove it is empty using a queued read.
  defp clear_executions! do
    guards =
      for {_id, pid, _type, [SynapsisSamgita.Execution.Guard]} <-
            DynamicSupervisor.which_children(SynapsisSamgita.DeviceSupervisor),
          is_pid(pid),
          do: pid

    for guard <- guards do
      ref = Process.monitor(guard)

      receive do
        {:DOWN, ^ref, :process, ^guard, _reason} -> :ok
      after
        5_000 -> flunk("execution guard did not finish before fixture cleanup")
      end
    end

    assert {:ok, %{succeeded: true, written: 0}} =
             Concord.Turso.replace_prefix("coord/samgita/executions/", [], timeout: 5_000)

    assert {:ok, [], %{has_more: false}} =
             Concord.Turso.list(
               prefix: "coord/samgita/executions/",
               keys_only: true,
               limit: 1,
               queue: true,
               timeout: 5_000
             )
  end

  defp enqueue(device_id \\ "device-1", task_id \\ "task-1") do
    Executions.enqueue(device_id, %{
      "project_ref" => "project-1",
      "task_ref" => task_id,
      "event_id" => "event-1"
    })
  end

  defp opts,
    do: [
      api: API,
      runtime: Runtime,
      connection: {:ok, %{agent_id: "agent-1", connection_id: "connection-1"}}
    ]

  test "each implementation executes the complete claim start progress report flow under its own identity" do
    for implementation <- ["synapsis", "codex", "sigma"] do
      Process.put(:calls, [])

      device = %{
        "id" => implementation,
        "source_id" => "source-#{implementation}",
        "implementation" => implementation
      }

      {:ok, :new, entry} = enqueue(implementation)

      assert {:ok, %{"phase" => "completed", "server_state" => "succeeded"}} =
               Worker.run(entry, device, opts())

      assert Process.get(:selected) == {implementation, "source-#{implementation}"}

      assert Enum.map(Process.get(:calls), &elem(&1, 0)) == [
               :session,
               :claim,
               :start,
               :progress,
               :report
             ]

      assert {:report, report} = List.last(Process.get(:calls))
      assert report[:resolved] == true
      assert report[:outcome] == "succeeded"
      {:ok, stored} = Executions.get(entry["id"])
      refute inspect(stored) =~ "secret-owner-proof"
      refute Map.has_key?(Executions.public(stored), "proof_encrypted")
    end
  end

  test "a lost claim response is never retried by duplicate event or worker restart" do
    Process.put(:fail_action, :claim)
    {:ok, :new, entry} = enqueue()

    assert {:ok, %{"phase" => "recovery_required"}} =
             Worker.run(entry, %{"id" => "device-1"}, opts())

    refute Process.get(:runtime_started, false)
    assert Enum.count(Process.get(:calls), &(elem(&1, 0) == :claim)) == 1
    assert {:ok, :existing, current} = enqueue()
    assert :ok = Worker.run(current, %{"id" => "device-1"}, opts())
    assert :ok = Worker.run(entry, %{"id" => "device-1"}, opts())
    assert Enum.count(Process.get(:calls), &(elem(&1, 0) == :claim)) == 1
    assert Executions.active?("device-1")
  end

  test "a thread and turn acknowledgement cannot complete a Task before a terminal event" do
    {:ok, :new, entry} = enqueue()
    test = self()

    task =
      Task.async(fn ->
        Process.put(:test, test)
        Process.put(:finish, false)
        Worker.run(entry, %{"id" => "device-1"}, opts())
      end)

    assert_receive {:progress_started, worker}, 2_000
    assert {:ok, %{"phase" => phase}} = Executions.get(entry["id"])
    assert phase in ["progress_requested", "running"]
    assert Task.yield(task, 20) == nil
    send(worker, :finished)
    assert {:ok, %{"phase" => "completed"}} = Task.await(task)
  end

  test "a lost report response keeps its operation identity and requires reconciliation" do
    Process.put(:fail_action, :report)
    handle = local_handle("codex")
    Process.put(:evidence_handle, handle)

    Process.put(:evidence_events, [
      local_event(handle, :item_completed, %{
        item: %{type: "agentMessage", text: "Verified before the report response was lost"}
      }),
      local_event(handle, :turn_completed, %{status: "completed"})
    ])

    {:ok, :new, entry} = enqueue()

    assert {:ok,
            %{"phase" => "recovery_required", "last_error" => "report_outcome_unconfirmed"} =
              result} =
             Worker.run(
               entry,
               %{"id" => "device-1"},
               Keyword.put(opts(), :runtime, EvidenceRuntime)
             )

    assert result["commands"]["report"] == entry["commands"]["report"]
    assert {:report, report} = List.last(Process.get(:calls))
    assert result["report"] == report[:journal]
    assert result["report"]["result"] == report[:result]
    assert report[:result]["summary"] == "Verified before the report response was lost"
    assert result["report"]["command_id"] == report[:command_id]
    assert {:ok, :existing, repeated} = enqueue()
    assert :ok = Worker.run(repeated, %{"id" => "device-1"}, opts())
    assert :ok = Worker.run(entry, %{"id" => "device-1"}, opts())
    assert Enum.count(Process.get(:calls), &(elem(&1, 0) == :report)) == 1
    assert {:ok, stored} = Executions.get(entry["id"])
    assert stored["report"] == result["report"]
  end

  test "runtime failure reports unresolved effects instead of accepting the Task" do
    Process.put(:terminal, :failed)
    {:ok, :new, entry} = enqueue()

    assert {:ok, %{"phase" => "recovery_required", "server_state" => "failed"}} =
             Worker.run(entry, %{"id" => "device-1"}, opts())

    assert {:report, report} = List.last(Process.get(:calls))
    assert report[:outcome] == "failed"
    assert report[:resolved] == false
  end

  test "owner loss fences the journal and cancels a runtime independent of the worker" do
    test = self()
    actor_id = Ecto.UUID.generate()

    actor =
      spawn(fn ->
        receive do
          {:start, ^test} ->
            send(test, {:runtime_started, self()})

            receive do
              {:cancel, ^test} -> send(test, {:runtime_cancelled, self()})
            end
        end
      end)

    :persistent_term.put({OwnerRuntime, actor_id}, {actor, test})

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      :persistent_term.erase({OwnerRuntime, actor_id})
      if Process.alive?(actor), do: Process.exit(actor, :kill)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    {:ok, :new, entry} = enqueue()

    task =
      Task.async(fn ->
        Process.put(:test, test)

        Worker.run(
          entry,
          %{"id" => "device-1", "actor_id" => actor_id},
          Keyword.merge(opts(), owner: owner, runtime: OwnerRuntime)
        )
      end)

    assert_receive {:runtime_started, ^actor}, 2_000
    assert_receive {:progress_started, _worker}, 2_000
    {:ok, active} = Executions.get(entry["id"])
    token = active["owner_token"]
    Process.exit(owner, :kill)
    assert_receive {:runtime_cancelled, ^actor}, 2_000
    assert {:error, :owner_lost} = Task.await(task)

    assert {:ok, %{"phase" => "recovery_required", "owner_token" => nil}} =
             Executions.get(entry["id"])

    assert {:error, :already_started} = Executions.update_owned(entry["id"], token, "completed")
    assert :ok = Worker.run(entry, %{"id" => "device-1"}, opts())
  end

  test "a completed root with active or uncertain children cannot resolve execution effects" do
    alias SynapsisSamgita.Execution.Runtime, as: RealRuntime

    assert {:done, "succeeded", true} =
             RealRuntime.completion(%{root: %{status: :completed}, agents: []})

    for status <- [:running, :waiting, :unknown_outcome, :errored] do
      assert {:done, "failed", false} =
               RealRuntime.completion(%{root: %{status: :completed}, agents: [%{status: status}]})
    end

    assert {:done, "failed", false} =
             RealRuntime.completion(%{
               root: %{status: :completed},
               agents: [%{status: :completed, cleanup: :uncertain}]
             })
  end

  test "real Synapsis Runtime reports only final public text from its exact terminal session" do
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Synapsis.Session.Store.delete_session(session_id) end)

    {:ok, _} =
      Synapsis.Message.append(session_id, %Synapsis.Message{
        role: "assistant",
        parts: [%Synapsis.Part.Text{content: "Earlier response"}]
      })

    {:ok, final} =
      Synapsis.Message.append(session_id, %Synapsis.Message{
        role: "assistant",
        parts: [
          %Synapsis.Part.Reasoning{content: "private reasoning"},
          %Synapsis.Part.ToolResult{content: "private tool response"},
          %Synapsis.Part.Text{content: "Synapsis final verification: ready."}
        ]
      })

    start_supervised!(
      {SnapshotSession,
       %{
         session: %{id: session_id},
         status: :waiting,
         subagents: %{root: %{status: :completed, run_id: "synapsis-run"}, agents: []}
       }}
    )

    Process.put(:evidence_handle, %{"kind" => "agent", "session_id" => session_id})
    Process.put(:evidence_events, [{"done", %{}}])
    {:ok, :new, entry} = enqueue("synapsis")

    assert {:ok, %{"phase" => "completed"}} =
             Worker.run(
               entry,
               %{"id" => "synapsis"},
               Keyword.put(opts(), :runtime, EvidenceRuntime)
             )

    assert {:report, report} = List.last(Process.get(:calls))

    assert report[:result] == %{
             "summary" => "Synapsis final verification: ready.",
             "runtime" => %{
               "kind" => "agent",
               "session_id" => session_id,
               "run_id" => "synapsis-run",
               "message_id" => final.id
             },
             "terminal_status" => "completed",
             "truncated" => false
           }

    assert report[:journal]["result"] == report[:result]
  end

  test "real Codex and Sigma Runtime report different bounded matching turn evidence" do
    alias SynapsisLocalAgents.Event

    for implementation <- ["codex", "sigma"] do
      Process.put(:calls, [])
      handle = local_handle(implementation)
      answer = "#{implementation} final verification: " <> String.duplicate("雪😀", 2_000)

      events = [
        local_event(handle, :item_completed, %{
          item: %{type: "agentMessage", text: "intermediate"}
        }),
        local_event(handle, :item_completed, %{item: %{type: "agentMessage", text: answer}}),
        {:local_agent_event,
         %Event{
           agent_id: implementation,
           thread_id: handle["thread_id"],
           turn_id: "different-turn",
           type: :turn_started
         }},
        local_event(Map.put(handle, "turn_id", "different-turn"), :item_completed, %{
          item: %{type: "agentMessage", text: "wrong turn"}
        }),
        local_event(handle, :item_completed, %{item: %{type: "reasoning", text: "private"}}),
        local_event(handle, :turn_completed, %{status: "completed"})
      ]

      Process.put(:evidence_handle, handle)
      Process.put(:evidence_events, events)
      {:ok, :new, entry} = enqueue(implementation)

      assert {:ok, %{"phase" => "completed"}} =
               Worker.run(
                 entry,
                 %{"id" => implementation},
                 Keyword.put(opts(), :runtime, EvidenceRuntime)
               )

      assert {:report, report} = List.last(Process.get(:calls))
      result = report[:result]
      assert result["summary"] =~ "#{implementation} final verification:"
      assert byte_size(result["summary"]) <= 4_096
      assert String.valid?(result["summary"])
      assert String.starts_with?(answer, result["summary"])
      assert result["truncated"]
      assert result["runtime"] == handle
      assert result["terminal_status"] == "completed"
      assert report[:journal]["result"] == result
      assert report[:journal]["command_id"] == entry["commands"]["report"]

      assert {:ok, :existing, repeated} = enqueue(implementation)
      assert :ok = Worker.run(repeated, %{"id" => implementation}, opts())
      assert Enum.count(Process.get(:calls), &(elem(&1, 0) == :session)) == 1
      assert Enum.count(Process.get(:calls), &(elem(&1, 0) == :report)) == 1
    end
  end

  test "two runs on one device preserve distinct public evidence and report identities" do
    reports =
      for number <- 1..2 do
        Process.put(:calls, [])
        handle = local_handle("codex") |> Map.put("turn_id", "turn-#{number}")
        Process.put(:evidence_handle, handle)

        Process.put(:evidence_events, [
          local_event(handle, :item_completed, %{
            item: %{type: "agentMessage", text: "Verified result #{number}"}
          }),
          local_event(handle, :turn_completed, %{status: "completed"})
        ])

        {:ok, :new, entry} = enqueue("codex", "task-#{number}")

        assert {:ok, %{"phase" => "completed"}} =
                 Worker.run(
                   entry,
                   %{"id" => "codex"},
                   Keyword.put(opts(), :runtime, EvidenceRuntime)
                 )

        {:ok, stored} = Executions.get(entry["id"])
        stored["report"]
      end

    assert [first, second] = reports
    refute first["command_id"] == second["command_id"]
    assert first["result"]["summary"] == "Verified result 1"
    assert second["result"]["summary"] == "Verified result 2"
    assert first["result"]["runtime"]["turn_id"] == "turn-1"
    assert second["result"]["runtime"]["turn_id"] == "turn-2"
  end

  test "real Synapsis failure reports the exact terminal session error" do
    session_id = Ecto.UUID.generate()

    start_supervised!(
      {SnapshotSession,
       %{
         session: %{id: session_id},
         status: :error,
         error: "Synapsis verification failed: dependency unavailable",
         subagents: %{root: %{status: :errored, run_id: "failed-run"}, agents: []}
       }}
    )

    Process.put(:evidence_handle, %{"kind" => "agent", "session_id" => session_id})
    Process.put(:evidence_events, [{"error", %{message: "untrusted event detail"}}])
    {:ok, :new, entry} = enqueue("synapsis")

    assert {:ok, %{"phase" => "recovery_required"}} =
             Worker.run(
               entry,
               %{"id" => "synapsis"},
               Keyword.put(opts(), :runtime, EvidenceRuntime)
             )

    assert {:report, report} = List.last(Process.get(:calls))
    assert report[:result]["summary"] == "Synapsis verification failed: dependency unavailable"
    assert report[:result]["runtime"]["run_id"] == "failed-run"
    refute report[:resolved]
  end

  test "known failed local terminal reports its reason with unresolved effects" do
    handle = local_handle("sigma")
    Process.put(:evidence_handle, handle)

    Process.put(:evidence_events, [
      local_event(handle, :turn_completed, %{
        status: "failed",
        error: "Sigma verification failed: expected artifact missing"
      })
    ])

    {:ok, :new, entry} = enqueue("sigma")

    assert {:ok, %{"phase" => "recovery_required", "server_state" => "failed"}} =
             Worker.run(entry, %{"id" => "sigma"}, Keyword.put(opts(), :runtime, EvidenceRuntime))

    assert {:report, report} = List.last(Process.get(:calls))
    assert report[:outcome] == "failed"
    refute report[:resolved]
    assert report[:result]["summary"] == "Sigma verification failed: expected artifact missing"
    assert report[:result]["runtime"] == handle
    assert report[:result]["terminal_status"] == "failed"
  end

  test "real Runtime ignores other identities and unknown local terminal statuses" do
    alias SynapsisSamgita.Execution.Runtime, as: RealRuntime
    handle = local_handle("codex")

    for changed <- [%{"source_id" => "other"}, %{"thread_id" => "other"}, %{"turn_id" => "other"}] do
      assert :pending =
               RealRuntime.observe(
                 handle,
                 local_event(Map.merge(handle, changed), :turn_completed, %{status: "completed"})
               )

      assert RealRuntime.capture(
               handle,
               local_event(Map.merge(handle, changed), :item_completed, %{
                 item: %{type: "agentMessage", text: "wrong execution"}
               })
             ) == handle
    end

    for status <- [nil, "running", "unrecognized"] do
      assert :pending =
               RealRuntime.observe(
                 handle,
                 local_event(handle, :turn_completed, %{status: status})
               )
    end

    assert {:done, "succeeded", true, result} =
             RealRuntime.observe(
               handle,
               local_event(handle, :turn_completed, %{status: "completed"})
             )

    assert result["summary"] =~ "No public text"
    assert result["runtime"] == handle
    refute result["truncated"]
  end

  test "a Synapsis operational error while running is not terminal evidence" do
    alias SynapsisSamgita.Execution.Runtime, as: RealRuntime
    session_id = Ecto.UUID.generate()

    start_supervised!(
      {SnapshotSession,
       %{
         session: %{id: session_id},
         status: :streaming,
         subagents: %{root: %{status: :running}, agents: []}
       }}
    )

    handle = %{"kind" => "agent", "session_id" => session_id}

    assert :pending =
             RealRuntime.observe(handle, {"error", %{message: "nonterminal operation error"}})

    assert :pending = RealRuntime.observe(handle, {"done", %{}})
  end

  test "unconverged Synapsis children report a concrete recovery reason" do
    session_id = Ecto.UUID.generate()

    start_supervised!(
      {SnapshotSession,
       %{
         session: %{id: session_id},
         status: :waiting,
         subagents: %{root: %{status: :completed}, agents: [%{status: :running}]}
       }}
    )

    Process.put(:evidence_handle, %{"kind" => "agent", "session_id" => session_id})
    Process.put(:evidence_events, [{"done", %{}}])
    {:ok, :new, entry} = enqueue("synapsis")

    assert {:ok, %{"phase" => "recovery_required"}} =
             Worker.run(
               entry,
               %{"id" => "synapsis"},
               Keyword.put(opts(), :runtime, EvidenceRuntime)
             )

    assert {:report, report} = List.last(Process.get(:calls))
    refute report[:resolved]
    assert report[:result]["summary"] =~ "unresolved"
    assert report[:result]["runtime"]["session_id"] == session_id
  end

  defp local_handle(id),
    do: %{
      "kind" => "local_agent",
      "source_id" => id,
      "thread_id" => "thread-#{id}",
      "turn_id" => "turn-#{id}"
    }

  defp local_event(handle, type, data),
    do:
      {:local_agent_event,
       %SynapsisLocalAgents.Event{
         agent_id: handle["source_id"],
         thread_id: handle["thread_id"],
         turn_id: handle["turn_id"],
         type: type,
         data: data
       }}

  test "a truncated journal cannot authorize disconnect" do
    for number <- 1..1_001, do: enqueue("many", "task-#{number}")
    assert {:error, :journal_truncated} = Executions.list("many")
    assert Executions.active?("many")
  end

  test "one selected device cannot deduplicate or read another device's execution" do
    {:ok, :new, one} = enqueue("one")
    {:ok, :new, two} = enqueue("two")
    refute one["id"] == two["id"]
    assert Enum.map(Executions.list("one"), & &1["id"]) == [one["id"]]
    assert {:ok, _} = Executions.start(one["id"])
    assert {:error, :already_started} = Executions.start(one["id"])
    assert {:ok, _} = Executions.start(two["id"])
  end

  test "Synapsis waiting snapshot and idle barrier both require a completed roster" do
    alias SynapsisSamgita.Execution.Runtime, as: RealRuntime
    session_id = Ecto.UUID.generate()

    start_supervised!(
      {SnapshotSession,
       %{
         session: %{id: session_id},
         status: :waiting,
         subagents: %{root: %{status: :completed}, agents: []}
       }}
    )

    handle = %{"kind" => "agent", "session_id" => session_id}
    assert {:done, "succeeded", true, _} = RealRuntime.observe(handle, {"done", %{}})

    assert {:done, "succeeded", true, _} =
             RealRuntime.observe(handle, {"session_status", %{status: "idle"}})
  end
end
