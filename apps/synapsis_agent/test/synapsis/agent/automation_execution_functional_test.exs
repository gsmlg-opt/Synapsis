defmodule Synapsis.Agent.AutomationExecutionFunctionalTest do
  use Synapsis.Agent.DataCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Automation.Execution, as: AutomationExecution
  alias Synapsis.Agent.Daemon.Execution, as: DaemonExecution
  alias Synapsis.AgentRun

  defmodule SessionsProbe do
    def automation_context(id, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        send(state.owner, {:context_read, id, opts})
        {state.context, %{state | reads: state.reads ++ [id]}}
      end)
    end

    def append_automation_result(id, text, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        send(state.owner, {:result_append, id, text, opts, not is_nil(state.completed)})
        {state.delivery, %{state | appends: state.appends ++ [{id, text}]}}
      end)
    end
  end

  defmodule RunsProbe do
    def mark_completed(run, summary, attrs) do
      Agent.get_and_update(SessionsProbe, fn state ->
        if state.completed do
          {{:error, :already_completed}, state}
        else
          terminal =
            run
            |> Map.merge(attrs)
            |> Map.merge(%{
              status: "completed",
              summary: summary,
              finished_at: DateTime.utc_now()
            })

          send(state.owner, {:completion_persisted, run.id})
          {{:ok, terminal}, %{state | completed: terminal}}
        end
      end)
    end

    def fetch(id) do
      Agent.get(SessionsProbe, fn
        %{completed: %{id: ^id} = terminal} -> {:ok, terminal}
        _ -> :not_found
      end)
    end
  end

  defmodule EventsProbe do
    def append_run_completed(_run), do: :ok
  end

  setup do
    owner = self()

    start_supervised!(%{
      id: SessionsProbe,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               owner: owner,
               context:
                 {:ok, %{source: :live, context: "Recent conversation:\n- User: Original"}},
               delivery: {:ok, %{status: :delivered, message_id: Ecto.UUID.generate()}},
               completed: nil,
               reads: [],
               appends: []
             }
           end,
           [name: SessionsProbe]
         ]}
    })

    :ok
  end

  test "versioned metadata freezes top-level configuration alongside existing run fields" do
    origin = origin()

    base = %{
      "routine_name" => "Canonical name",
      "routine_schedule" => %{"generation" => "current"},
      "automation_ref" => %{"source" => "routine", "id" => Ecto.UUID.generate()}
    }

    config = %{
      "automation_contract_version" => 1,
      "automation_origin" => origin,
      "session_target" => "current",
      "wake_mode" => "now",
      "delivery" => %{"mode" => "announce"},
      "metadata" => %{
        "retained" => %{"custom" => true},
        "routine_name" => "Old display",
        "automation_ref" => %{"source" => "routine", "id" => Ecto.UUID.generate()},
        "routine_schedule" => %{"generation" => "previous"},
        "session_target" => "isolated"
      }
    }

    metadata = AutomationExecution.metadata(config, base)
    assert metadata["routine_name"] == "Canonical name"
    assert metadata["automation_ref"] == base["automation_ref"]
    assert metadata["routine_schedule"] == base["routine_schedule"]
    assert metadata["retained"] == %{"custom" => true}

    assert AutomationExecution.metadata(config, %{"heartbeat_name" => "Direct heartbeat"}) ==
             Map.merge(
               Map.take(
                 config,
                 ~w(automation_contract_version automation_origin session_target wake_mode delivery)
               ),
               %{"heartbeat_name" => "Direct heartbeat", "retained" => %{"custom" => true}}
             )

    assert Map.take(
             metadata,
             ~w(automation_contract_version automation_origin session_target wake_mode delivery)
           ) ==
             Map.take(
               config,
               ~w(automation_contract_version automation_origin session_target wake_mode delivery)
             )

    assert AutomationExecution.metadata(Map.delete(config, "automation_contract_version"), base) ==
             base
  end

  test "current context is prepended to exact authored bytes and records its original source" do
    run = run()
    before_read = System.monotonic_time(:millisecond)
    {prompt, metadata} = AutomationExecution.prepare(run, SessionsProbe, run.prompt)

    assert prompt == "Recent conversation:\n- User: Original\n\n" <> run.prompt
    assert Map.delete(metadata, "automation_context") == run.metadata

    assert metadata["automation_context"] == %{
             "status" => "available",
             "source" => "live",
             "source_session_id" => run.metadata["automation_origin"]["session_id"]
           }

    assert_receive {:context_read, source_id, [deadline: deadline]}
    assert source_id == run.metadata["automation_origin"]["session_id"]
    assert deadline > before_read
    assert deadline <= before_read + 5_000
    assert run.prompt == "  Authored automation\nwith exact bytes  \n"
  end

  test "an empty source context keeps authored bytes and explicitly records the empty observation" do
    Agent.update(SessionsProbe, &%{&1 | context: {:ok, %{source: :durable, context: nil}}})
    run = run()
    assert {prompt, metadata} = AutomationExecution.prepare(run, SessionsProbe, run.prompt)
    assert prompt == run.prompt
    assert metadata["automation_context"]["status"] == "empty"
    assert metadata["automation_context"]["source"] == "durable"

    assert metadata["automation_context"]["source_session_id"] ==
             run.metadata["automation_origin"]["session_id"]

    assert Agent.get(SessionsProbe, & &1.reads) == [
             run.metadata["automation_origin"]["session_id"]
           ]
  end

  test "isolated execution retains its prompt and original binding without reading conversation context" do
    run = run(%{"session_target" => "isolated"})
    assert {prompt, metadata} = AutomationExecution.prepare(run, SessionsProbe, run.prompt)
    assert prompt == run.prompt
    assert metadata["automation_context"]["status"] == "omitted"

    assert metadata["automation_context"]["source_session_id"] ==
             run.metadata["automation_origin"]["session_id"]

    assert metadata["automation_origin"] == run.metadata["automation_origin"]
    assert Agent.get(SessionsProbe, & &1.reads) == []
  end

  test "ordinary legacy and dream preparation preserves the existing prompt and metadata" do
    for run <- [
          run() |> Map.put(:metadata, %{"legacy" => true}),
          run() |> Map.put(:kind, "dream")
        ] do
      base_prompt = run.prompt <> "Existing execution context"

      assert AutomationExecution.prepare(run, SessionsProbe, base_prompt) ==
               {base_prompt, run.metadata}

      assert AutomationExecution.delivery_metadata(run) == run.metadata
    end

    assert Agent.get(SessionsProbe, & &1.reads) == []
    assert Agent.get(SessionsProbe, & &1.appends) == []
  end

  test "announce observations distinguish delivered and ephemeral deferred source appends" do
    for status <- [:delivered, :deferred] do
      run = run() |> Map.merge(%{status: "completed", summary: "Result\nexact bytes  "})
      message_id = Ecto.UUID.generate()

      Agent.update(
        SessionsProbe,
        &%{&1 | delivery: {:ok, %{status: status, message_id: message_id}}}
      )

      assert {:ok, observation} = AutomationExecution.deliver(run, SessionsProbe, 500)
      assert observation["status"] == Atom.to_string(status)
      assert observation["source_session_id"] == run.metadata["automation_origin"]["session_id"]
      assert observation["message_id"] == message_id
      assert_receive {:result_append, source_id, "Result\nexact bytes  ", [timeout: 500], false}
      assert source_id == run.metadata["automation_origin"]["session_id"]

      assert [%{payload: ^observation}] =
               Synapsis.AgentEvents.list(work_id: run.id, event_type: "automation.delivery")
    end
  end

  test "none records suppressed delivery while preserving the completed run" do
    run =
      run(%{"delivery" => %{"mode" => "none"}})
      |> Map.merge(%{status: "completed", summary: "Kept in run"})

    assert {:ok, observation} = AutomationExecution.deliver(run, SessionsProbe, 500)
    assert observation["status"] == "suppressed"
    assert observation["source_session_id"] == run.metadata["automation_origin"]["session_id"]

    assert AutomationExecution.delivery_metadata(run)["automation_delivery"]["status"] ==
             "suppressed"

    assert Agent.get(SessionsProbe, & &1.appends) == []

    assert [%{payload: ^observation}] =
             Synapsis.AgentEvents.list(work_id: run.id, event_type: "automation.delivery")

    assert run.status == "completed"
  end

  test "completion persists before its one delivery attempt and reobserving terminal state does not append again" do
    run = run()
    supervisor = start_supervised!(Task.Supervisor)
    deps = %{runs: RunsProbe, run_events: EventsProbe, sessions: SessionsProbe}
    session_id = Ecto.UUID.generate()

    assert {:ok, terminal, []} =
             DaemonExecution.finalize(
               deps,
               run,
               {:ok, "Final completed result"},
               session_id,
               supervisor,
               1_000
             )

    assert terminal.status == "completed"
    assert terminal.session_id == session_id
    assert terminal.metadata["automation_origin"] == run.metadata["automation_origin"]
    assert terminal.metadata["automation_delivery"]["status"] == "pending"
    assert_receive {:completion_persisted, run_id}
    assert run_id == run.id
    assert_receive {:result_append, source_id, "Final completed result", [timeout: 1_000], true}
    assert source_id == run.metadata["automation_origin"]["session_id"]

    assert {:ok, ^terminal, [_already_completed]} =
             DaemonExecution.finalize(
               deps,
               run,
               {:ok, "Final completed result"},
               session_id,
               supervisor,
               1_000
             )

    assert Agent.get(SessionsProbe, & &1.appends) == [{source_id, "Final completed result"}]

    assert [%{payload: %{"status" => "delivered"}}] =
             Synapsis.AgentEvents.list(work_id: run.id, event_type: "automation.delivery")
  end

  defp origin, do: %{"agent_id" => Ecto.UUID.generate(), "session_id" => Ecto.UUID.generate()}

  defp run(metadata \\ %{}) do
    %AgentRun{
      id: Ecto.UUID.generate(),
      kind: "schedule",
      status: "running",
      assistant_name: "automation-functional",
      prompt: "  Authored automation\nwith exact bytes  \n",
      tool_profile: "native_agent",
      metadata:
        Map.merge(
          %{
            "automation_contract_version" => 1,
            "automation_origin" => origin(),
            "session_target" => "current",
            "delivery" => %{"mode" => "announce"},
            "retained" => %{"unknown" => true}
          },
          metadata
        )
    }
  end
end
