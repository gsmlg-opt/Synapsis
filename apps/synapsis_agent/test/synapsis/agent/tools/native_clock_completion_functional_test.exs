defmodule Synapsis.Agent.Tools.NativeClockCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Agent.Tools.{Approval, NativeLocal, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @duration 400
  @source """
  // @exec: {"yield_time_ms": 1}
  text("before-clock");
  const elapsed = await tools.clock__sleep({duration_ms: 400});
  text(elapsed);
  text("after-clock");
  return {marker: "nested-consumer", wall_time_seconds: elapsed.wall_time_seconds};
  """

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:clock_provider, request, self()})

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
  end

  defmodule ObservedStore do
    @behaviour Backplane.AgentRuntime.Store

    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store
    defdelegate new(incarnation), to: Store
    defdelegate load(context, run_id, opts), to: Store

    def store(context, record, meta),
      do: observe(context, meta, Store.store(context, record, meta))

    def acknowledge_commit(context, stage, meta),
      do: observe(context, meta, Store.acknowledge_commit(context, stage, meta))

    # Forward the real Concord acknowledgement unchanged, holding only its return.
    defp observe(context, %{command: {kind, _, input}}, {:ok, acknowledgement} = result) do
      if kind in [:tool_invoked, :tool_completed] and input[:tool_name] == "clock::sleep" do
        send(
          context.test_pid,
          {:clock_commit_ready, kind, input, acknowledgement.revision, self()}
        )

        receive do
          {:release_clock_ack, ^kind} -> :ok
        after
          10_000 -> raise "ordinary clock Store observation was not released"
        end
      end

      send(context.test_pid, {:clock_store_ack, kind, acknowledgement.revision})
      result
    end

    defp observe(_context, _meta, result), do: result
  end

  test "Conversation consumes one successful native clock after durable ACK and waiter exit", %{
    tmp_dir: root
  } do
    fixture = setup_runtime(root, ["clock::sleep"])

    conversation =
      start_supervised!(
        {Conversation,
         fixture.options ++ [provider: Provider, provider_context: %{observer: self()}]}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Wait once, then continue")
    assert_receive {:clock_provider, first_request, provider}, 5_000
    assert [%{name: "clock::sleep"}] = first_request.tools

    send(provider, {:events, [clock_call(), done("waiting")]})
    {operation, lifecycle, result} = complete_clock(fixture)
    assert operation.enclosing_invocation_id == operation.invocation_id

    assert_receive {:clock_provider, next_request, next_provider}, 5_000
    assert [message] = Enum.filter(next_request.messages, &(&1[:role] == :tool))
    assert message.tool_call_id == "ordinary-clock"
    assert message.result == result
    send(next_provider, {:events, [done("ordinary clock consumed")]})

    status = await_completed(conversation, deadline())

    aggregate =
      assert_durable(fixture, status.run, operation, result, ["clock::sleep"], [
        first_request,
        next_request
      ])

    assert aggregate.run.context.conversation.messages == status.messages
    assert Enum.filter(status.messages, &(&1[:role] == :tool)) == [message]
    refute_receive {:clock_provider, _, _}, 0
    assert_normal_close(fixture, aggregate)
    assert_lifecycle(lifecycle)
  end

  test "Headless delivers the nested clock reply only after real ACK and closes Deno normally", %{
    tmp_dir: root
  } do
    fixture = setup_runtime(root, ~w(exec wait clock::sleep))
    assert {:ok, occurrence} = Headless.start_link(fixture.options)

    on_exit(fn ->
      if Process.alive?(occurrence), do: GenServer.stop(occurrence, :normal, 5_000)
    end)

    assert {:ok, _} = Headless.execute(occurrence, @source)
    {operation, lifecycle, clock_result} = complete_clock(fixture)
    assert operation.enclosing_invocation_id != operation.invocation_id

    assert {:ok, result} = Headless.await(occurrence, timeout: 10_000)
    assert result.status == :completed

    assert result.value == %{
             "marker" => "nested-consumer",
             "wall_time_seconds" => clock_result.wall_time_seconds
           }

    assert result.nested_invocations == 1
    assert result.outer_reservations == 1
    assert result.output_truncated == false
    assert [before_clock, elapsed, after_clock] = result.output
    assert before_clock == %{"type" => "text", "text" => "before-clock"}
    assert after_clock == %{"type" => "text", "text" => "after-clock"}
    assert elapsed["type"] == "text"

    assert Jason.decode!(elapsed["text"]) == %{
             "wall_time_seconds" => clock_result.wall_time_seconds
           }

    assert %{phase: :terminal, resource_cleanup: :confirmed, run: record} =
             Headless.status(occurrence)

    aggregate = assert_durable(fixture, record, operation, clock_result, ~w(clock::sleep exec))
    assert record.context.conversation.headless_result == result
    assert Map.get(record, :provider_attempts, %{}) == %{}
    refute_receive {:clock_provider, _, _}, 0
    assert_normal_close(fixture, aggregate)
    assert %{deno: {deno, monitor, os_pid}} = lifecycle
    assert_receive {:DOWN, ^monitor, :process, ^deno, :normal}, 5_000
    refute File.exists?("/proc/#{os_pid}")
    assert_lifecycle(lifecycle)
  end

  defp setup_runtime(root, selection) do
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id

    permission = %Synapsis.SessionPermission{
      session_id: session_id,
      tool_contract_version: 1
    }

    assert :ok = SessionStore.put_value(session_id, "permission", permission)
    on_exit(fn -> SessionStore.delete_session(session_id) end)

    context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{tools: selection, tool_contract_version: 1},
      project_path: root
    }

    identity = %{
      caller: caller,
      session_id: session_id,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    authority = %{
      caller: caller,
      run_id: run_id,
      grants: selection,
      tool_revision: 1,
      tool_revisions: Map.new(selection, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    assert {:ok, local} =
             NativeLocal.bundles(
               %{
                 workspace: root,
                 caller: %{run_id: run_id},
                 session_registry: binding.resource_registry,
                 session_binding: binding
               },
               authority,
               selection
             )

    assert {:ok, code_mode} =
             HostCodeMode.bundles(%{session_binding: binding}, authority, selection)

    assert {:ok, %{bundle: catalog, snapshot: snapshot}} =
             Profiles.build(context, identity, local ++ code_mode, authority)

    assert catalog.registry.tools["clock::sleep"].backend == Codex.Backend
    assert catalog.registry.tools["clock::sleep"].backend_context.family == :local
    assert {:ok, store} = Store.new(1)
    store = Map.put(store, :test_pid, self())

    options = [
      run_id: run_id,
      incarnation: 1,
      session_binding: binding,
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      store: ObservedStore,
      context: store,
      hooks: Policy,
      host_context: %{
        tool_context_resolver: fn invocation, pinned ->
          Profiles.project_catalog(invocation, snapshot, pinned)
        end,
        tool_operator_id: Approval.operator_id()
      },
      subscriber: self(),
      work: 8,
      run_timeout: 30_000,
      effect_timeout: 15_000,
      commit_timeout: 15_000,
      cleanup_timeout: 5_000
    ]

    %{
      session: session,
      binding: binding,
      store: store,
      run_id: run_id,
      caller: caller,
      options: options
    }
  end

  defp complete_clock(fixture) do
    assert_receive {:clock_commit_ready, :tool_invoked, input, revision, writer}, 5_000
    assert {:ok, saved} = Store.load(fixture.store, fixture.run_id)
    assert saved.revision == revision
    operation = saved.run.execution_intents["tool:#{input.invocation_id}"].operation
    assert operation.tool_name == "clock::sleep"
    assert operation.arguments == %{"duration_ms" => @duration}
    assert operation.run_id == fixture.run_id
    assert operation.caller == fixture.caller
    assert operation.incarnation == 1
    assert operation.catalog_revision == 1
    assert operation.tool_revision == 1
    assert operation.invocation_id == input.invocation_id
    refute Map.has_key?(saved.run.tool_results, operation.invocation_id)

    binding = fixture.binding
    assert {:ok, supervisor} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    children_before = DynamicSupervisor.which_children(supervisor)
    refute Enum.any?(children_before, &clock_worker?/1)
    assert {:ok, resources_before} = owner_status(binding)

    deno =
      case children_before do
        [] ->
          nil

        [{_, pid, _, [CodeMode.Worker]}] ->
          assert {:ok, identity} = CodeMode.Worker.os_identity(pid)
          assert File.exists?("/proc/#{identity.pid}")
          {pid, Process.monitor(pid), identity.pid}
      end

    release_ack(writer, :tool_invoked, revision)
    {lifecycle, completion} = observe_waiter(binding, supervisor, resources_before, deadline())

    {:clock_commit_ready, :tool_completed, completed, result_revision, result_writer} = completion
    assert completed.invocation_id == operation.invocation_id
    assert {:ok, before_reply} = Store.load(fixture.store, fixture.run_id)
    assert before_reply.revision == result_revision
    result = before_reply.run.tool_results[operation.invocation_id]
    assert %{wall_time_seconds: elapsed, is_error: false} = result
    assert Map.keys(result) |> Enum.sort() == [:is_error, :wall_time_seconds]
    assert is_float(elapsed)
    assert elapsed > 0

    assert before_reply.run.execution_intents["tool:#{operation.invocation_id}"].operation ==
             operation

    assert {:ok, ^before_reply} =
             Synapsis.Runtime.Store.load(fixture.store.namespace, fixture.run_id)

    refute_receive {:clock_provider, _, _}, 0
    invocation_id = operation.invocation_id

    refute_receive {:agent_runtime, _,
                    %{type: :tool_settled, invocation: %{invocation_id: ^invocation_id}}},
                   0

    lifecycle = observe_completed_waiter(lifecycle, binding)
    release_ack(result_writer, :tool_completed, result_revision)

    lifecycle =
      Map.put(lifecycle, :resources_after_ack, await_release(binding, lifecycle, deadline()))

    {operation, Map.put(lifecycle, :deno, deno), result}
  end

  # A missing old-version waiter is recorded without interrupting the ordinary
  # success. Both real ACKs, the consumer, and Session.close finish before RED.
  defp observe_waiter(binding, supervisor, resources_before, expiry) do
    case Enum.filter(DynamicSupervisor.which_children(supervisor), &clock_worker?/1) do
      [{_, pid, _, _}] ->
        monitor = Process.monitor(pid)
        assert {:ok, resources} = owner_status(binding)
        before_ids = Enum.map(resources_before, & &1.id)
        added = Enum.reject(resources, &(&1.id in before_ids))

        lifecycle = %{
          waiter: pid,
          monitor: monitor,
          added: added,
          alive_during_wait: Process.alive?(pid)
        }

        assert_receive completion = {:clock_commit_ready, :tool_completed, _, _, _}, 5_000
        {lifecycle, completion}

      [] ->
        receive do
          completion = {:clock_commit_ready, :tool_completed, _, _, _} ->
            {%{waiter: nil}, completion}
        after
          5 ->
            assert System.monotonic_time(:millisecond) < expiry
            observe_waiter(binding, supervisor, resources_before, expiry)
        end
    end
  end

  defp observe_completed_waiter(%{waiter: nil} = lifecycle, _binding), do: lifecycle

  defp observe_completed_waiter(%{waiter: pid, monitor: monitor} = lifecycle, binding) do
    reason =
      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> reason
      after
        1_000 -> :not_observed
      end

    assert {:ok, resources} = owner_status(binding)

    Map.merge(lifecycle, %{
      down_before_ack: reason,
      alive_before_ack: Process.alive?(pid),
      resources_before_ack: resources
    })
  end

  defp await_release(_binding, %{waiter: nil}, _expiry), do: nil

  defp await_release(binding, lifecycle, expiry) do
    assert {:ok, resources} = owner_status(binding)
    ids = Enum.map(lifecycle.added, & &1.id)

    if Enum.any?(resources, &(&1.id in ids)) and System.monotonic_time(:millisecond) < expiry do
      Process.sleep(5)
      await_release(binding, lifecycle, expiry)
    else
      resources
    end
  end

  defp assert_lifecycle(lifecycle) do
    assert is_pid(lifecycle.waiter),
           "ordinary native clock must allocate an owned ClockWait.Worker"

    assert lifecycle.alive_during_wait
    assert [%{id: id, kind: :resource, status: :active, reason: nil} = resource] = lifecycle.added
    assert lifecycle.down_before_ack == :normal
    refute lifecycle.alive_before_ack
    assert resource in lifecycle.resources_before_ack
    refute Enum.any?(lifecycle.resources_after_ack, &(&1.id == id))
  end

  defp assert_durable(fixture, record, operation, result, names, provider_requests \\ []) do
    assert {:ok, aggregate} = Store.load(fixture.store, fixture.run_id)
    assert aggregate.run == record
    assert aggregate.revision == record.expected_revision
    assert record.state == :completed
    assert record.tool_results[operation.invocation_id] == result
    assert map_size(record.tool_results) == length(names)

    {tool_operations, provider_operations} = classify_intents(record.execution_intents)
    assert map_size(record.execution_intents) == length(names) + length(provider_requests)
    assert map_size(tool_operations) == length(names)
    assert Enum.sort(Enum.map(Map.values(tool_operations), & &1.tool_name)) == Enum.sort(names)
    assert tool_operations["tool:#{operation.invocation_id}"] == operation

    assert Enum.sort(Enum.map(Map.values(tool_operations), & &1.invocation_id)) ==
             Enum.sort(Map.keys(record.tool_results))

    assert provider_operations ==
             Map.new(provider_requests, &{"provider:#{&1.attempt_id}", &1})

    if provider_requests != [] do
      assert length(provider_requests) == 2

      assert record.provider_attempts ==
               Map.new(provider_requests, fn request ->
                 {request.attempt_id,
                  Map.take(request, [:run_id, :incarnation, :step_id, :attempt_id])}
               end)
    end

    assert {:ok, ^aggregate} =
             Synapsis.Runtime.Store.load(fixture.store.namespace, fixture.run_id)

    refute_receive {:clock_commit_ready, _, _, _, _}, 0
    aggregate
  end

  defp classify_intents(intents) do
    Enum.reduce(intents, {%{}, %{}}, fn
      {"tool:" <> invocation_id = key,
       %{
         type: :tool,
         status: :consumed,
         operation: %{invocation_id: actual_id, tool_name: name} = operation,
         reservation: %{reservation_id: reservation_id}
       }},
      {tools, providers} ->
        assert invocation_id == actual_id
        assert reservation_id == key
        assert is_binary(name)
        {Map.put(tools, key, operation), providers}

      {"provider:" <> attempt_id = key,
       %{
         type: :provider,
         status: :consumed,
         operation: %{attempt_id: actual_id, messages: messages, tools: tools} = operation,
         reservation: %{reservation_id: reservation_id}
       }},
      {tool_operations, providers} ->
        assert attempt_id == actual_id
        assert reservation_id == key
        assert is_list(messages)
        assert is_list(tools)
        {tool_operations, Map.put(providers, key, operation)}

      unexpected, _acc ->
        flunk("unexpected durable execution intent: #{inspect(unexpected)}")
    end)
  end

  defp assert_normal_close(fixture, aggregate) do
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(fixture.session)

    assert {:ok, ^aggregate} = Store.load(fixture.store, fixture.run_id)
  end

  defp release_ack(writer, kind, revision) do
    send(writer, {:release_clock_ack, kind})
    assert_receive {:clock_store_ack, ^kind, ^revision}, 1_000
  end

  defp owner_status(binding),
    do: ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)

  defp clock_worker?({_, pid, _, modules}),
    do: is_pid(pid) and Backplane.AgentRuntime.Codex.ClockWait.Worker in modules

  defp await_completed(conversation, expiry) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}, resource_cleanup: :confirmed} = status ->
        status

      status ->
        assert System.monotonic_time(:millisecond) < expiry, inspect(status)
        Process.sleep(5)
        await_completed(conversation, expiry)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp clock_call,
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "ordinary-clock",
        name: "clock::sleep",
        arguments: %{"duration_ms" => @duration}
      }
    }

  defp done(content),
    do: %{type: :response_completed, message: %{role: :assistant, content: content}}
end
