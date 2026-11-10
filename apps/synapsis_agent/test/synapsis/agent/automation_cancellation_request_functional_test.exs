defmodule Synapsis.Agent.AutomationCancellationRequestFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.RunEvents
  alias Synapsis.AgentRun.Store, as: RunStore

  defmodule Sessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_id), do: []
    def cancel(_id), do: :ok

    def send_message(id, prompt) do
      send(owner(), {:automation_session_started, prompt, id})
      :ok
    end

    defp owner do
      Application.fetch_env!(:synapsis_agent, :automation_cancellation_test_owner)
    end
  end

  defmodule ControlledRuns do
    alias Synapsis.Agent.Runs

    def create(attrs) do
      result = Runs.create(attrs)

      if String.starts_with?(attrs.prompt, "persist ") do
        send(owner(), {:automation_persistence, self(), attrs.id, result})

        receive do
          :acknowledge_persistence -> result
        end
      else
        result
      end
    end

    def list_by_status_result("queued" = status, opts) do
      result = Runs.list_by_status_result(status, opts)

      if Application.get_env(:synapsis_agent, :automation_cancellation_scan) do
        send(owner(), {:automation_queued_scan, self(), result})

        receive do
          :acknowledge_scan -> result
        end
      else
        result
      end
    end

    def list_by_status_result(status, opts), do: Runs.list_by_status_result(status, opts)
    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate fetch_by_idempotency_key(key), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs

    def mark_interrupted(run, reason) do
      if Application.get_env(:synapsis_agent, :automation_cancellation_interrupt) do
        send(owner(), {:automation_before_interruption, self(), run.id})

        receive do
          :acknowledge_interruption -> :ok
        end
      end

      Runs.mark_interrupted(run, reason)
    end

    defp owner do
      Application.fetch_env!(:synapsis_agent, :automation_cancellation_test_owner)
    end
  end

  setup do
    keys = [
      :automation_cancellation_test_owner,
      :automation_cancellation_scan,
      :automation_cancellation_interrupt
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:synapsis_agent, &1)})
    Application.put_env(:synapsis_agent, :automation_cancellation_test_owner, self())
    Application.delete_env(:synapsis_agent, :automation_cancellation_scan)
    Application.delete_env(:synapsis_agent, :automation_cancellation_interrupt)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:synapsis_agent, key, value)
        {key, :error} -> Application.delete_env(:synapsis_agent, key)
      end)
    end)

    :ok
  end

  test "one request captures active queued and registered producers for the exact source" do
    {server, _supervisor} = start_test_daemon(sessions: Sessions)
    daemon = Process.whereis(server)
    id = Ecto.UUID.generate()
    target = {"routine", id}

    assert {:ok, active} = trigger(daemon, target, "active exact source")
    assert_receive {:automation_session_started, "active exact source", _}, 2_000
    assert {:ok, _} = wait_for_run(active.id, "running")
    assert {:ok, queued} = trigger(daemon, target, "queued exact source")
    assert {:ok, sibling} = trigger(daemon, {"heartbeat", id}, "same UUID sibling")
    {producer, producer_ref} = registered_producer(daemon, target, "paused exact source")

    request_ref = make_ref()
    observation = cancellation_request(daemon, target, request_ref)
    assert MapSet.new(observation.retired_run_ids) == MapSet.new([active.id, queued.id])
    assert observation.identity_complete == false
    assert observation.status == :cancellation_requested
    assert observation.target == target
    assert observation.active_count == 1
    assert observation.queued_count == 1
    assert observation.producer_count == 1
    assert observation.cleanup_pending

    send(producer, :submit)
    assert_receive {:automation_producer_result, ^producer_ref, {:ok, produced}}, 2_000
    produced_id = produced.id
    assert_receive {:automation_retirement_runs, ^request_ref, ^daemon, [^produced_id]}, 2_000
    assert_receive {:automation_retirement_identity_complete, ^request_ref, ^daemon}, 2_000

    for run <- [active, queued, produced] do
      assert {:ok, cancelled} = wait_for_run(run.id, "cancelled")
      assert cancelled.metadata["automation_ref"] == %{"source" => "routine", "id" => id}
      assert_cancelled_fact(run.id)
    end

    assert_receive {:automation_session_started, "same UUID sibling", _}, 2_000
    assert {:ok, _} = wait_for_run(sibling.id, "running")

    assert Runs.get(sibling.id).metadata["automation_ref"] == %{
             "source" => "heartbeat",
             "id" => id
           }

    {future, future_ref} = registered_producer(daemon, target, "future exact source")
    send(future, :submit)
    assert_receive {:automation_producer_result, ^future_ref, {:ok, future_run}}, 2_000
    assert future_run.status == "queued"
    assert {:ok, %{status: "cancelled"}} = Daemon.cancel(daemon, sibling.id)
    assert_receive {:automation_session_started, "future exact source", _}, 2_000
    assert {:ok, _} = wait_for_run(future_run.id, "running")
    assert {:ok, %{status: "cancelled"}} = Daemon.cancel(daemon, future_run.id)
  end

  test "an acknowledged request retains a submitted generated ID until persistence resolves" do
    {server, _supervisor} = start_test_daemon(sessions: Sessions, runs: ControlledRuns)
    daemon = Process.whereis(server)
    target = {"routine", Ecto.UUID.generate()}
    {producer, producer_ref} = registered_producer(daemon, target, "persist exact source")
    send(producer, :submit)

    assert_receive {:automation_persistence, task, generated_id, {:ok, created}}, 2_000
    assert generated_id == created.id
    request_ref = make_ref()
    observation = cancellation_request(daemon, target, request_ref)
    assert observation.retired_run_ids == [generated_id]
    assert observation.identity_complete == false
    assert observation.submission_count == 1
    assert observation.cleanup_pending
    assert Process.alive?(task)

    send(task, :acknowledge_persistence)
    assert_receive {:automation_producer_result, ^producer_ref, {:ok, returned}}, 2_000
    assert returned.id == generated_id
    assert_receive {:automation_retirement_runs, ^request_ref, ^daemon, [^generated_id]}, 2_000
    assert_receive {:automation_retirement_identity_complete, ^request_ref, ^daemon}, 2_000
    assert {:ok, _} = wait_for_run(generated_id, "cancelled")
    assert_cancelled_fact(generated_id)
    assert {:ok, facts} = RunStore.list_events(generated_id)
    assert Enum.map(facts, & &1["type"]) == ["run.created", "run.cancelled"]
  end

  test "an ordinary idempotent submission transfers cancellation to its actual durable Run" do
    id = Ecto.UUID.generate()
    target = {"routine", id}
    key = "automation-cancellation-#{Ecto.UUID.generate()}"

    {:ok, attrs} =
      Synapsis.Agent.Daemon.Execution.routine_attrs(:schedule, options(target, "alias"))

    assert {:ok, existing} = Runs.create(Map.put(attrs, :idempotency_key, key))
    {server, _supervisor} = start_test_daemon(sessions: Sessions, runs: ControlledRuns)
    daemon = Process.whereis(server)

    {producer, producer_ref} =
      registered_producer(daemon, target, "persist idempotent alias", %{idempotency_key: key})

    send(producer, :submit)
    assert_receive {:automation_persistence, task, generated_id, {:ok, aliased}}, 2_000
    assert aliased.id == existing.id
    assert is_binary(generated_id)
    request_ref = make_ref()
    observation = cancellation_request(daemon, target, request_ref)
    assert observation.submission_count == 1
    assert observation.identity_complete == false
    send(task, :acknowledge_persistence)

    assert_receive {:automation_producer_result, ^producer_ref, {:ok, returned}}, 2_000
    assert returned.id == existing.id
    existing_id = existing.id
    assert_receive {:automation_retirement_runs, ^request_ref, ^daemon, [^existing_id]}, 2_000
    assert_receive {:automation_retirement_identity_complete, ^request_ref, ^daemon}, 2_000
    assert {:ok, _} = wait_for_run(existing.id, "cancelled")
    assert_cancelled_fact(existing.id)
    assert Runs.get_by_idempotency_key(key).id == existing.id
  end

  test "a pending recovery keeps the request through its following refill chain" do
    id = Ecto.UUID.generate()
    target = {"routine", id}

    runs =
      for {ref, prompt} <- [
            {target, "recovery exact source"},
            {target, "refill exact source"},
            {{"heartbeat", id}, "recovered sibling"}
          ] do
        {:ok, attrs} =
          Synapsis.Agent.Daemon.Execution.routine_attrs(:schedule, options(ref, prompt))

        {:ok, run} = Runs.create(attrs)
        run
      end

    Application.put_env(:synapsis_agent, :automation_cancellation_scan, true)

    {server, _supervisor} =
      start_test_daemon(
        sessions: Sessions,
        runs: ControlledRuns,
        recover?: true,
        queue_capacity: 1
      )

    daemon = Process.whereis(server)
    assert_receive {:automation_queued_scan, recovery, {:ok, _}}, 2_000
    request_ref = make_ref()
    observation = cancellation_request(daemon, target, request_ref)
    assert observation.retired_run_ids == []
    assert observation.identity_complete == false
    assert observation.pending_recovery_count == 1
    assert observation.cleanup_pending
    Application.delete_env(:synapsis_agent, :automation_cancellation_scan)
    send(recovery, :acknowledge_scan)
    assert_receive {:automation_retirement_runs, ^request_ref, ^daemon, recovered_ids}, 2_000
    assert MapSet.new(recovered_ids) == MapSet.new(Enum.map(Enum.take(runs, 2), & &1.id))

    for run <- Enum.take(runs, 2) do
      assert {:ok, _} = wait_for_run(run.id, "cancelled")
      assert_cancelled_fact(run.id)
      assert {:ok, facts} = RunStore.list_events(run.id)
      assert Enum.map(facts, & &1["type"]) == ["run.created", "run.cancelled"]
    end

    assert_receive {:automation_retirement_identity_complete, ^request_ref, ^daemon}, 2_000

    sibling = List.last(runs)
    assert_receive {:automation_session_started, "recovered sibling", _}, 2_000
    assert {:ok, _} = wait_for_run(sibling.id, "running")
    assert {:ok, %{status: "cancelled"}} = Daemon.cancel(daemon, sibling.id)
  end

  test "recovery observations acquired before a request retain interrupted Run identity" do
    target = {"routine", Ecto.UUID.generate()}

    {:ok, attrs} =
      Synapsis.Agent.Daemon.Execution.routine_attrs(
        :schedule,
        options(target, "recovery running")
      )

    assert {:ok, created} = Runs.create(attrs)
    assert {:ok, running} = Runs.mark_running(created)
    running_id = running.id
    Application.put_env(:synapsis_agent, :automation_cancellation_interrupt, true)

    {server, _supervisor} =
      start_test_daemon(sessions: Sessions, runs: ControlledRuns, recover?: true)

    daemon = Process.whereis(server)
    assert_receive {:automation_before_interruption, recovery, ^running_id}, 2_000
    request_ref = make_ref()
    observation = cancellation_request(daemon, target, request_ref)
    assert observation.retired_run_ids == [running_id]
    assert observation.identity_complete == false
    assert observation.pending_recovery_count == 1
    send(recovery, :acknowledge_interruption)

    assert {:ok, interrupted} = wait_for_run(running_id, "interrupted")

    assert interrupted.metadata["automation_ref"] == %{
             "source" => elem(target, 0),
             "id" => elem(target, 1)
           }

    assert_receive {:automation_retirement_identity_complete, ^request_ref, ^daemon}, 2_000
    assert {:ok, facts} = RunStore.list_events(running_id)
    assert List.last(facts)["type"] == "run.interrupted"
  end

  defp options({source, id}, prompt) do
    %{
      prompt: prompt,
      routine_id: id,
      no_overlap: false,
      metadata: %{"automation_ref" => %{"source" => source, "id" => id}}
    }
  end

  defp trigger(daemon, target, prompt),
    do: Daemon.trigger(daemon, :schedule, options(target, prompt))

  defp registered_producer(daemon, target, prompt, extra \\ %{}) do
    owner = self()
    ref = make_ref()

    producer =
      spawn(fn ->
        monitor = Process.monitor(daemon)

        receive do
          {:automation_producer_ready, ^ref, ^daemon} ->
            send(owner, {:automation_producer_paused, ref})

            receive do
              :submit ->
                result =
                  Daemon.trigger(daemon, :schedule, Map.merge(options(target, prompt), extra))

                send(owner, {:automation_producer_result, ref, result})

              {:DOWN, ^monitor, :process, ^daemon, _} ->
                :ok
            end

          {:DOWN, ^monitor, :process, ^daemon, _} ->
            :ok
        end
      end)

    on_exit(fn -> if Process.alive?(producer), do: Process.exit(producer, :kill) end)
    assert :ok = Daemon.register_automation_producer(daemon, owner, ref, producer, target)
    assert_receive {:automation_producer_ready, ^ref, ^daemon}, 2_000
    assert_receive {:automation_producer_paused, ^ref}, 2_000
    {producer, ref}
  end

  defp cancellation_request(daemon, target, ref) do
    assert :ok = Daemon.request_automation_cancellation(daemon, self(), ref, target)
    assert_receive {:automation_cancellation_requested, ^ref, observation}, 2_000
    observation
  end

  defp assert_cancelled_fact(id) do
    assert {:ok, facts} = RunStore.list_events(id)
    assert Enum.count(facts, &(&1["type"] == "run.cancelled")) == 1
    assert List.last(RunEvents.list_for_run(id))["type"] == "run.cancelled"
  end
end
