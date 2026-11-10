defmodule Synapsis.Agent.Tools.HeadlessHostContextFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Agent.Tools.{Approval, NativeLocal, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @selection ~w(exec wait clock::curr_time exec_command)
  @source """
  // @exec: {"yield_time_ms": 1}
  text("before");
  text(await tools.clock__curr_time({}));
  const shell = await tools.exec_command({
    cmd: input.command, login: false, tty: false, yield_time_ms: 1000
  });
  text(shell);
  store("marker", "continued");
  yield "ordinary-pause";
  text(load("marker"));
  text(await tools.clock__curr_time({}));
  text("after");
  return {value: input.value, shellExitCode: shell.exit_code, shellOutput: shell.output};
  """

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

    # The real durable commit has succeeded. Hold only its return to the runtime,
    # so the test can observe ordinary intent/result acknowledgement ordering.
    defp observe(context, %{command: {kind, _, input}}, {:ok, acknowledgement} = result) do
      if kind in [:tool_invoked, :tool_completed] and input[:tool_name] == "exec_command" do
        send(
          context.test_pid,
          {:host_context_commit_ready, kind, input, acknowledgement.revision, self()}
        )

        receive do
          {:release_host_context_ack, ^kind} -> :ok
        after
          5_000 -> raise "ordinary host-context Store observation was not released"
        end
      end

      send(context.test_pid, {:host_context_store_ack, kind, acknowledgement.revision})
      result
    end

    defp observe(_context, _meta, result), do: result
  end

  test "original Policy composes with provider-free Headless and real durable ACKs", %{
    tmp_dir: root
  } do
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    path = Path.join(root, "headless-host-context-count.txt")

    # This is the real persisted host input read by Profiles/Freshness, rather
    # than a prepared allow sidecar or an alternate Policy implementation.
    permission = %Synapsis.SessionPermission{
      session_id: session_id,
      tool_contract_version: 1
    }

    assert :ok = SessionStore.put_value(session_id, "permission", permission)
    on_exit(fn -> SessionStore.delete_session(session_id) end)

    context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{tools: @selection, tool_contract_version: 1},
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
      grants: @selection,
      tool_revision: 1,
      tool_revisions: Map.new(@selection, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)
    assert {:ok, local_runtime} = NativeLocal.open(@selection, nil)

    on_exit(fn ->
      if Process.alive?(local_runtime.server),
        do: GenServer.stop(local_runtime.server, :normal, 5_000)
    end)

    local_context = %{
      workspace: root,
      caller: %{run_id: run_id},
      command: local_runtime.command,
      session_registry: binding.resource_registry,
      session_binding: binding
    }

    assert {:ok, local} = NativeLocal.bundles(local_context, authority, @selection)

    assert {:ok, code_mode} =
             HostCodeMode.bundles(%{session_binding: binding}, authority, @selection)

    assert {:ok, %{bundle: catalog, snapshot: snapshot}} =
             Profiles.build(context, identity, local ++ code_mode, authority)

    assert Enum.sort(Map.keys(catalog.registry.tools)) == Enum.sort(@selection)
    assert snapshot.permission == permission
    assert snapshot.skill_snapshot == nil

    for original <- local ++ code_mode, {name, descriptor} <- original.registry.tools do
      assert catalog.registry.tools[name] === descriptor
      assert descriptor.backend == Codex.Backend
      assert descriptor.backend_context.session_binding == binding
    end

    assert catalog.registry.tools["exec"].backend_context.family == :code_mode
    assert catalog.registry.tools["exec_command"].backend_context.family == :local
    assert catalog.registry.tools["clock::curr_time"].backend_context.family == :local

    observer = self()

    resolver = fn invocation, pinned ->
      result = Profiles.project_catalog(invocation, snapshot, pinned)
      send(observer, {:host_context_resolved, invocation, pinned, result})
      result
    end

    assert {:ok, store} = Store.new(1)
    store = Map.put(store, :test_pid, observer)

    opts = [
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
        tool_context_resolver: resolver,
        tool_operator_id: Approval.operator_id()
      },
      subscriber: observer,
      work: 8,
      run_timeout: 30_000,
      effect_timeout: 15_000,
      commit_timeout: 10_000,
      cleanup_timeout: 5_000
    ]

    refute Keyword.has_key?(opts, :provider)
    refute Keyword.has_key?(opts, :provider_context)
    assert {:ok, occurrence} = Headless.start_link(opts)

    on_exit(fn ->
      if Process.alive?(occurrence), do: GenServer.stop(occurrence, :normal, 5_000)
    end)

    input = %{
      "value" => 42,
      "command" => "printf 'run\\n' >> headless-host-context-count.txt; printf nested-shell"
    }

    assert {:ok, %{run_id: ^run_id, incarnation: 1}} =
             Headless.execute(occurrence, @source, input: input)

    assert_receive {:host_context_resolved, outer, pinned, {:ok, outer_snapshot}}, 5_000
    assert outer.tool_name == "exec"
    assert outer.arguments == @source
    assert_pinned(outer, pinned, outer_snapshot, identity, catalog)

    assert_receive {:host_context_resolved, first_clock, ^pinned, {:ok, clock_snapshot}}, 5_000
    assert first_clock.tool_name == "clock::curr_time"
    assert first_clock.enclosing_invocation_id == outer.invocation_id
    assert_pinned(first_clock, pinned, clock_snapshot, identity, catalog)

    assert_receive {:host_context_resolved, shell, ^pinned, {:ok, shell_snapshot}}, 5_000
    assert shell.tool_name == "exec_command"
    assert shell.enclosing_invocation_id == outer.invocation_id

    assert shell.arguments == %{
             "cmd" => input["command"],
             "login" => false,
             "tty" => false,
             "yield_time_ms" => 1000
           }

    assert_pinned(shell, pinned, shell_snapshot, identity, catalog)
    shell_id = shell.invocation_id

    assert_receive {:host_context_commit_ready, :tool_invoked, intent_input, intent_revision,
                    intent_writer},
                   5_000

    assert intent_input.invocation_id == shell_id
    assert {:ok, before_effect} = Store.load(store, run_id)
    intent = before_effect.run.execution_intents["tool:#{shell_id}"]

    identity_fields =
      ~w(run_id incarnation invocation_id tool_name tool_revision catalog_revision enclosing_invocation_id)a

    assert Map.take(intent.operation, identity_fields) == Map.take(shell, identity_fields)
    assert intent.operation.caller == caller
    assert before_effect.revision == intent_revision
    refute Map.has_key?(before_effect.run.tool_results, shell_id)
    refute File.exists?(path)

    assert {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    assert [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    assert {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    assert Process.alive?(worker)
    assert File.exists?("/proc/#{os_identity.pid}")
    worker_monitor = Process.monitor(worker)
    send(intent_writer, {:release_host_context_ack, :tool_invoked})
    assert_receive {:host_context_store_ack, :tool_invoked, ^intent_revision}, 1_000

    assert_receive {:host_context_commit_ready, :tool_completed, completed_input, result_revision,
                    result_writer},
                   5_000

    assert completed_input.invocation_id == shell_id
    assert {:ok, before_reply} = Store.load(store, run_id)
    assert before_reply.revision == result_revision

    assert %{exit_code: 0, output: "nested-shell", is_error: false} =
             before_reply.run.tool_results[shell_id]

    assert File.read!(path) == "run\n"

    refute_receive {:agent_runtime, ^run_id,
                    %{type: :tool_settled, invocation: %{invocation_id: ^shell_id}}},
                   0

    refute_receive {:host_context_resolved, _, _, _}, 0
    send(result_writer, {:release_host_context_ack, :tool_completed})
    assert_receive {:host_context_store_ack, :tool_completed, ^result_revision}, 1_000

    assert_receive {:host_context_resolved, second_clock, ^pinned, {:ok, next_snapshot}}, 5_000
    assert second_clock.tool_name == "clock::curr_time"
    assert second_clock.invocation_id != first_clock.invocation_id
    assert second_clock.enclosing_invocation_id == outer.invocation_id
    assert_pinned(second_clock, pinned, next_snapshot, identity, catalog)

    assert {:ok, result} = Headless.await(occurrence, timeout: 10_000)
    assert result.status == :completed

    assert result.value == %{
             "value" => 42,
             "shellExitCode" => 0,
             "shellOutput" => "nested-shell"
           }

    assert result.nested_invocations == 3
    assert result.outer_reservations == 1
    assert result.output_truncated == false
    assert [before, clock_one, shell_output, continued, clock_two, after_output] = result.output
    assert before == %{"type" => "text", "text" => "before"}
    assert continued == %{"type" => "text", "text" => "continued"}
    assert after_output == %{"type" => "text", "text" => "after"}
    assert shell_output["type"] == "text"
    assert %{"exit_code" => 0, "output" => "nested-shell"} = Jason.decode!(shell_output["text"])

    for clock_output <- [clock_one, clock_two] do
      assert clock_output["type"] == "text"
      assert %{"current_time" => time} = Jason.decode!(clock_output["text"])
      assert time =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$/
    end

    assert {:ok, aggregate} = Store.load(store, run_id)

    assert %{phase: :terminal, resource_cleanup: :confirmed, run: record} =
             Headless.status(occurrence)

    assert aggregate.run == record
    assert record.state == :completed
    assert record.context.execution_mode == :headless
    assert record.context.conversation.headless_result == result
    assert aggregate.revision == record.expected_revision
    assert_receive {:host_context_store_ack, :finish, final_revision}, 1_000
    assert final_revision == aggregate.revision
    assert map_size(record.tool_results) == 4
    assert Map.get(record, :provider_attempts, %{}) == %{}

    names =
      for {_, execution_intent} <- record.execution_intents,
          do: execution_intent.operation.tool_name

    assert Enum.sort(names) == ~w(clock::curr_time clock::curr_time exec exec_command)
    refute_receive {:host_context_store_ack, :provider_started, _}, 0
    refute_receive {:host_context_resolved, _, _, _}, 0
    assert File.read!(path) == "run\n"

    # Observe normal native cleanup; do not call cleanup_identity or send signals.
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5_000
    refute File.exists?("/proc/#{os_identity.pid}")
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} = Session.status(session)
    assert {:ok, ^aggregate} = Store.load(store, run_id)
    assert File.read!(path) == "run\n"
  end

  defp assert_pinned(invocation, pinned, snapshot, identity, catalog) do
    assert Map.take(invocation, [:run_id, :incarnation, :catalog_revision]) ==
             Map.take(identity, [:run_id, :incarnation, :catalog_revision])

    assert pinned.revision == identity.catalog_revision
    assert pinned.registry == catalog.registry
    assert pinned.tools == catalog.tools
    assert pinned.authority == catalog.authority
    assert snapshot.issued_descriptors == catalog.registry.tools
    assert snapshot.scope.run_id == identity.run_id
    assert snapshot.scope.incarnation == identity.incarnation
    assert snapshot.scope.catalog_revision == identity.catalog_revision
  end
end
