defmodule Synapsis.Agent.Tools.ResourceLifecycleTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  # These are process-local native contract observations with inert supervised
  # workers, not shell/device cleanup or production Concord recovery evidence.
  setup do
    registry = start_supervised!({ResourceRegistry, cleanup_timeout: 200})
    caller = start_supervised!(Task.Supervisor)
    %{registry: registry, caller: caller}
  end

  test "foreign and stale handles cannot stop workers; exact release stops once", ctx do
    {worker, monitor} = worker(ctx.registry)
    {borrowed, _} = worker(ctx.registry)
    cleanup = cleanup(worker)

    assert {:ok, handle} =
             ResourceRegistry.register(ctx.registry, "owner", :logical, worker,
               incarnation: 2,
               cleanup: cleanup
             )

    assert {:ok, session} =
             ResourceRegistry.register_session(ctx.registry, "borrower", borrowed,
               incarnation: 3,
               cleanup: cleanup(borrowed)
             )

    for operation <- [:fetch, :release] do
      assert {:error, %Error{class: :forbidden}} =
               apply(ResourceRegistry, operation, [ctx.registry, handle, "foreign"])

      assert {:error, %Error{class: :resource_conflict}} =
               apply(ResourceRegistry, operation, [
                 ctx.registry,
                 %{handle | incarnation: 1},
                 "owner"
               ])
    end

    assert {:error, %Error{class: :forbidden}} =
             ResourceRegistry.release_session(ctx.registry, session, "owner", 3)

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.release_session(ctx.registry, session, "borrower", 2)

    assert Process.alive?(worker)
    assert Process.alive?(borrowed)
    refute_receive {:cleanup, _, _}, 20

    assert {:ok, :done} = ResourceRegistry.release(ctx.registry, handle, "owner")
    assert_receive {:cleanup, ^worker, _}, 500
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    refute Process.alive?(worker)

    assert {:ok, :done} = ResourceRegistry.release(ctx.registry, handle, "owner")

    assert {:ok, %{status: :confirmed, reason: nil}} =
             ResourceRegistry.cleanup_status(ctx.registry, handle, "owner")

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch(ctx.registry, handle, "owner")

    assert {:ok, ^borrowed} =
             ResourceRegistry.fetch_session(ctx.registry, session, "borrower", 3)

    assert Process.alive?(borrowed)
    refute_receive {:cleanup, _, _}, 20
  end

  test "owner death cleans its actual worker and closes admission without touching another owner",
       ctx do
    {:ok, owner} = Task.Supervisor.start_child(ctx.caller, &wait/0)
    owner_monitor = Process.monitor(owner)
    {worker, monitor} = worker(ctx.registry)
    {other, _} = worker(ctx.registry)

    {:ok, handle} =
      ResourceRegistry.register(ctx.registry, "lost-owner", :logical, worker,
        owner_pid: owner,
        cleanup: cleanup(worker)
      )

    {:ok, other_handle} =
      ResourceRegistry.register(ctx.registry, "other-owner", :logical, other,
        cleanup: cleanup(other)
      )

    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 500
    assert_receive {:cleanup, ^worker, _}, 500
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    assert {:ok, %{status: :confirmed}} = settled(ctx.registry, handle, "lost-owner")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.register(ctx.registry, "lost-owner", :logical, :replacement)

    assert {:ok, ^other} = ResourceRegistry.fetch(ctx.registry, other_handle, "other-owner")
    assert Process.alive?(other)
    refute_receive {:cleanup, _, _}, 20
  end

  test "cleanup timeout kills the cleanup task but retains the live resource for reconciliation",
       ctx do
    test_pid = self()
    {worker, _} = worker(ctx.registry)

    {:ok, handle} =
      ResourceRegistry.register(ctx.registry, "blocked-owner", :logical, worker,
        cleanup: fn ->
          send(test_pid, {:cleanup_blocked, self()})
          wait()
        end
      )

    release =
      Task.Supervisor.async_nolink(ctx.caller, fn ->
        ResourceRegistry.close_owner(ctx.registry, "blocked-owner")
      end)

    assert_receive {:cleanup_blocked, cleanup_task}, 500
    cleanup_monitor = Process.monitor(cleanup_task)
    {other, other_monitor} = worker(ctx.registry)

    {:ok, other_handle} =
      ResourceRegistry.register(ctx.registry, "responsive-owner", :logical, other,
        cleanup: cleanup(other)
      )

    assert {:ok, :done} = ResourceRegistry.release(ctx.registry, other_handle, "responsive-owner")
    assert_receive {:DOWN, ^other_monitor, :process, ^other, :normal}, 500

    assert {:ok, [{:error, %Error{class: :unknown_outcome}}]} = Task.await(release, 1_000)
    assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup_task, reason}, 500
    assert reason in [:killed, :noproc]
    refute Process.alive?(cleanup_task)
    assert Process.alive?(worker)

    assert {:ok, %{status: :uncertain, reason: :cleanup_timeout}} =
             ResourceRegistry.cleanup_status(ctx.registry, handle, "blocked-owner")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.fetch(ctx.registry, handle, "blocked-owner")

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.register(ctx.registry, "blocked-owner", :logical, :replacement)

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.release(ctx.registry, handle, "blocked-owner")

    refute_receive {:cleanup_blocked, _}, 20
  end

  for reason <- [:cancel, :deadline] do
    test "Conversation #{reason} stops its provider and native catalog-owned resource", ctx do
      run_id = unquote("resource-#{reason}")
      {worker, monitor} = worker(ctx.registry)
      {other, _} = worker(ctx.registry)
      {:ok, workers} = ResourceRegistry.worker_supervisor(ctx.registry)

      {:ok, other_handle} =
        ResourceRegistry.register(ctx.registry, "other-owner", :logical, other,
          cleanup: cleanup(other)
        )

      {:ok, handle} =
        ResourceRegistry.register(ctx.registry, run_id, :logical, worker,
          cleanup: cleanup(worker)
        )

      options = conversation_options(ctx.registry, run_id)

      options =
        Keyword.put(options, :run_timeout, unquote(if reason == :deadline, do: 200, else: 5_000))

      pid = conversation(options)
      assert {:ok, _} = Proof.prompt(ctx.caller, pid, "wait without calling tools")
      assert_receive {:provider_started, ^run_id, provider}, 500
      provider_monitor = Process.monitor(provider)

      if unquote(reason == :cancel), do: assert(:ok == Conversation.cancel(pid))

      assert_receive {:DOWN, ^provider_monitor, :process, ^provider, _}, 1_000
      assert_receive {:cleanup, ^worker, _}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
      assert_receive {:agent_runtime, ^run_id, %{type: :run_cancelled}}, 1_000
      assert Conversation.status(pid).resource_cleanup == :confirmed
      assert Conversation.status(pid).phase == :terminal

      assert {:ok, %{status: :confirmed}} =
               ResourceRegistry.cleanup_status(ctx.registry, handle, run_id)

      assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, run_id)

      assert {:error, %Error{class: :resource_conflict}} =
               ResourceRegistry.register(ctx.registry, run_id, :logical, :replacement)

      assert {:error, %Error{class: :resource_conflict}} =
               Proof.prompt(ctx.caller, pid, "must not restart")

      assert Conversation.status(pid).run.active_tools == %{}
      refute_receive {:provider_started, ^run_id, _}, 20

      assert :ok = GenServer.stop(pid, :normal, 1_000)
      assert Process.alive?(ctx.registry)
      assert Process.alive?(workers)
      assert {:ok, ^other} = ResourceRegistry.fetch(ctx.registry, other_handle, "other-owner")
      assert Process.alive?(other)
      refute_receive {:cleanup, _, _}, 20
    end
  end

  test "Session close releases resources; termination separately stops its owned registry tree" do
    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 500})
    {:ok, binding} = Session.bind(session, authority("session-resource"))
    registry = binding.resource_registry
    registry_monitor = Process.monitor(registry)
    {:ok, workers} = ResourceRegistry.worker_supervisor(registry)
    supervisor_monitor = Process.monitor(workers)
    {worker, monitor} = worker(registry)

    {:ok, _} =
      ResourceRegistry.register(registry, binding.owner_id, :logical, worker,
        incarnation: binding.incarnation,
        owner_pid: session,
        cleanup: cleanup(worker)
      )

    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 500
    assert Session.status(session).phase == :closed
    assert Process.alive?(session)
    assert Process.alive?(registry)
    assert Process.alive?(workers)

    assert :ok = GenServer.stop(session, :normal, 1_000)
    assert_receive {:DOWN, ^registry_monitor, :process, ^registry, :normal}, 1_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^workers, _}, 1_000
    refute Process.alive?(registry)
    refute Process.alive?(workers)
  end

  test "restoring a live run inspects its snapshot without replaying provider or resource effects",
       ctx do
    run_id = "resource-restore"
    options = conversation_options(ctx.registry, run_id)
    pid = conversation(options)
    {worker, monitor} = worker(ctx.registry)

    {:ok, handle} =
      ResourceRegistry.register(ctx.registry, run_id, :logical, worker, cleanup: cleanup(worker))

    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "start once")
    assert_receive {:provider_started, ^run_id, _}, 500
    assert {:ok, %{run: run}} = EphemeralStore.load(options[:context], run_id)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:cleanup, ^worker, _}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert_receive {:agent_runtime, ^run_id, %{type: :run_cancelled}}, 1_000
    assert {:ok, before_restore} = EphemeralStore.load(options[:context], run_id)

    restored = conversation(Keyword.put(options, :run, run))
    assert Conversation.status(restored).phase == :recovery_required
    assert Conversation.status(restored).run == run

    assert {:error, %Error{class: :resource_conflict}} =
             Proof.prompt(ctx.caller, restored, "must not replay")

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch(ctx.registry, handle, run_id)

    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, run_id)
    assert {:ok, ^before_restore} = EphemeralStore.load(options[:context], run_id)
    refute_receive {:provider_started, ^run_id, _}, 20
    refute_receive {:cleanup, _, _}, 20
  end

  defp worker(registry) do
    {:ok, supervisor} = ResourceRegistry.worker_supervisor(registry)
    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {Task, &wait/0})
    {pid, Process.monitor(pid)}
  end

  defp wait do
    receive do
      :stop -> :ok
    end
  end

  defp cleanup(worker) do
    test_pid = self()

    fn ->
      monitor = Process.monitor(worker)
      send(test_pid, {:cleanup, worker, self()})
      send(worker, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^worker, :normal} -> :done
      after
        100 -> {:uncertain, :worker_did_not_stop}
      end
    end
  end

  defp settled(registry, handle, owner, attempts \\ 100) do
    case ResourceRegistry.cleanup_status(registry, handle, owner) do
      {:ok, %{status: :in_progress}} when attempts > 0 ->
        receive do
        after
          5 -> settled(registry, handle, owner, attempts - 1)
        end

      status ->
        status
    end
  end

  defp authority(run_id),
    do: %{
      caller: "resource-proof",
      run_id: run_id,
      grants: ["clock::curr_time"],
      tool_revision: 1
    }

  defp conversation_options(registry, run_id) do
    test_pid = self()

    {:ok, bundle} =
      Codex.profile(:pinned_local, %{resource_registry: registry}, authority(run_id),
        tools: ["clock::curr_time"]
      )

    script = fn request ->
      send(test_pid, {:provider_started, request.run_id, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end

    Proof.options(run_id, script,
      registry: bundle.registry,
      tools: bundle.tools,
      authority: bundle.authority,
      schema_admission: :strict
    )
  end

  defp conversation(options) do
    start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
  end
end
