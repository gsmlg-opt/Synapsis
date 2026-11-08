defmodule Synapsis.Agent.Tools.HeadlessFilesystemFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Agent.Tools.{Approval, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @read_source """
  // @exec: {"yield_time_ms": 1000}
  return await tools.synapsis__file_read(input.arguments);
  """
  @mutation_source """
  // @exec: {"yield_time_ms": 1000}
  const write = await tools.synapsis__file_write(input.write);
  const edit = await tools.synapsis__file_edit(input.edit);
  const multi = await tools.synapsis__multi_edit(input.multi);
  const move = await tools.synapsis__file_move(input.move);
  const list = await tools.synapsis__list_dir(input.list);
  const grep = await tools.synapsis__grep(input.grep);
  const glob = await tools.synapsis__glob(input.glob);
  const deleted = await tools.synapsis__file_delete(input.deleted);
  return {write, edit, multi, move, list, grep, glob, deleted};
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

    # Persist through the real Store first. Hold only the first target intent's
    # actual acknowledgement so worker monitoring cannot race a tiny file read.
    defp observe(context, %{command: {kind, _, input}}, {:ok, acknowledgement} = result) do
      if kind == :tool_invoked and input[:tool_name] == context.observed_tool do
        send(
          context.test_pid,
          {:filesystem_intent_committed, input, acknowledgement.revision, self()}
        )

        receive do
          {:release_filesystem_ack, id} when id == input.invocation_id -> :ok
        after
          5_000 -> raise "ordinary filesystem Store acknowledgement was not released"
        end
      end

      send(context.test_pid, {:filesystem_store_ack, kind, acknowledgement.revision})
      result
    end

    defp observe(_context, _meta, result), do: result
  end

  test "provider-free Headless reads a real file through the original native filesystem descriptor",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "read.txt"), "native workflow read\n")
    fixture = open_fixture(root, ~w(exec wait synapsis::file_read))
    input = %{"arguments" => %{"path" => "read.txt"}}

    assert {:ok, %{run_id: run_id, incarnation: 1}} =
             Headless.execute(fixture.occurrence, @read_source, input: input)

    assert run_id == fixture.identity.run_id
    outer = receive_outer(fixture, @read_source)
    {read, gate} = receive_target(fixture, outer, "synapsis::file_read", input["arguments"])
    send(gate, {:release_filesystem_context, read.invocation_id})
    worker = observe_committed_worker(fixture, outer, read)

    expected = %{
      content: "native workflow read\n",
      structured: %{
        path: "read.txt",
        content: "native workflow read\n",
        offset: 0,
        next_offset: nil,
        truncated: false,
        partial_line: false
      },
      is_error: false
    }

    assert {:ok, result} = Headless.await(fixture.occurrence, timeout: 10_000)
    assert result.value == json_value(Map.delete(expected, :is_error))
    aggregate = assert_terminal(fixture, outer, result, [{read, expected}], worker)
    assert File.read!(Path.join(root, "read.txt")) == "native workflow read\n"
    close_fixture(fixture, aggregate)
    assert File.read!(Path.join(root, "read.txt")) == "native workflow read\n"
  end

  test "one finite Headless flow writes edits moves lists searches and deletes real files",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "companion.txt"), "other\n")

    names =
      ~w(exec wait synapsis::file_write synapsis::file_edit synapsis::multi_edit synapsis::file_move synapsis::list_dir synapsis::grep synapsis::glob synapsis::file_delete)

    fixture = open_fixture(root, names)

    input = %{
      "write" => %{"path" => "draft.txt", "content" => "one\nkeep\n"},
      "edit" => %{"path" => "draft.txt", "old_string" => "one", "new_string" => "two"},
      "multi" => %{
        "edits" => [
          %{"path" => "draft.txt", "old_string" => "two", "new_string" => "three"},
          %{"path" => "companion.txt", "old_string" => "other", "new_string" => "final"}
        ]
      },
      "move" => %{"source" => "draft.txt", "destination" => "moved.txt"},
      "list" => %{"path" => ".", "depth" => 1},
      "grep" => %{"path" => ".", "pattern" => "three|final", "include" => "*.txt"},
      "glob" => %{"path" => ".", "pattern" => "*.txt"},
      "deleted" => %{"path" => "moved.txt"}
    }

    expected = [
      {"write", "synapsis::file_write",
       %{
         content: "created: draft.txt",
         structured: %{status: "created", path: "draft.txt", bytes: 9},
         is_error: false
       }},
      {"edit", "synapsis::file_edit",
       %{
         content: "updated: draft.txt",
         structured: %{status: "updated", path: "draft.txt", bytes: 9},
         is_error: false
       }},
      {"multi", "synapsis::multi_edit",
       %{
         content: "Multi-edit updated: 2 file(s).",
         structured: %{
           status: "updated",
           files: [
             %{path: "companion.txt", status: "updated", bytes: 6},
             %{path: "draft.txt", status: "updated", bytes: 11}
           ]
         },
         is_error: false
       }},
      {"move", "synapsis::file_move",
       %{
         content: "moved: draft.txt -> moved.txt",
         structured: %{status: "moved", source: "draft.txt", destination: "moved.txt"},
         is_error: false
       }},
      {"list", "synapsis::list_dir",
       %{
         content: "companion.txt\nmoved.txt",
         structured: %{
           entries: [
             %{path: "companion.txt", type: "file"},
             %{path: "moved.txt", type: "file"}
           ],
           truncated: false,
           next_offset: nil
         },
         is_error: false
       }},
      {"grep", "synapsis::grep",
       %{
         content: "companion.txt:1:final\nmoved.txt:1:three",
         structured: %{
           matches: [
             %{path: "companion.txt", line: 1, text: "final"},
             %{path: "moved.txt", line: 1, text: "three"}
           ],
           truncated: false,
           next_offset: nil
         },
         is_error: false
       }},
      {"glob", "synapsis::glob",
       %{
         content: "companion.txt\nmoved.txt",
         structured: %{
           paths: ["companion.txt", "moved.txt"],
           truncated: false,
           next_offset: nil
         },
         is_error: false
       }},
      {"deleted", "synapsis::file_delete",
       %{
         content: "deleted: moved.txt",
         structured: %{status: "deleted", path: "moved.txt"},
         is_error: false
       }}
    ]

    assert {:ok, %{run_id: run_id, incarnation: 1}} =
             Headless.execute(fixture.occurrence, @mutation_source, input: input)

    assert run_id == fixture.identity.run_id
    outer = receive_outer(fixture, @mutation_source)

    {operations, worker} =
      Enum.map_reduce(expected, nil, fn {key, name, expected_result}, worker ->
        {invocation, gate} = receive_target(fixture, outer, name, input[key])
        assert_previous_effect(root, key)
        send(gate, {:release_filesystem_context, invocation.invocation_id})
        worker = worker || observe_committed_worker(fixture, outer, invocation)
        {{invocation, expected_result}, worker}
      end)

    assert {:ok, result} = Headless.await(fixture.occurrence, timeout: 10_000)

    assert result.value ==
             Map.new(expected, fn {key, _name, value} ->
               {key, json_value(Map.delete(value, :is_error))}
             end)

    aggregate = assert_terminal(fixture, outer, result, operations, worker)
    assert File.ls!(root) == ["companion.txt"]
    assert File.read!(Path.join(root, "companion.txt")) == "final\n"
    close_fixture(fixture, aggregate)
    assert File.ls!(root) == ["companion.txt"]
    assert File.read!(Path.join(root, "companion.txt")) == "final\n"
  end

  defp open_fixture(root, names) do
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "headless-filesystem-#{session_id}",
               enabled: true,
               tools: names,
               tool_contract_version: 1,
               permission_mode: "yolo"
             })

    permission = %Synapsis.SessionPermission{
      session_id: session_id,
      mode: :autonomous,
      allow_read: :allow,
      allow_write: :allow,
      allow_execute: :allow,
      allow_destructive: :allow,
      tool_contract_version: 1
    }

    assert :ok = SessionStore.put_value(session_id, "permission", permission)

    on_exit(fn ->
      SessionStore.delete_session(session_id)
      Synapsis.AgentConfigs.delete(agent)
    end)

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
      grants: names,
      tool_revision: 1,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    assert {:ok, native} =
             HostCodeMode.bundles(%{session_binding: binding}, authority, names)

    context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{name: agent.name, tools: names, tool_contract_version: 1},
      project_path: root
    }

    assert {:ok, %{bundle: catalog, snapshot: snapshot}} =
             Profiles.build(context, identity, native, authority)

    assert Enum.sort(Map.keys(catalog.registry.tools)) == Enum.sort(names)
    assert snapshot.permission == permission
    assert catalog.registry.tools["exec"].backend == Codex.Backend

    filesystem_context = %{
      root: root,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1,
      workspace: %{role: :session, agent_id: agent.name, session_id: session_id}
    }

    assert {:ok, descriptors} = Filesystem.descriptors(filesystem_context)

    for descriptor <- descriptors, descriptor.tool_name in names do
      assert catalog.registry.tools[descriptor.tool_name] === descriptor
    end

    observer = self()

    resolver = fn invocation, pinned ->
      projected = Profiles.project_catalog(invocation, snapshot, pinned)
      send(observer, {:filesystem_context, invocation, pinned, projected, self()})

      if invocation.tool_name in Filesystem.names() do
        receive do
          {:release_filesystem_context, id} when id == invocation.invocation_id -> :ok
        after
          5_000 -> raise "ordinary filesystem context observation was not released"
        end
      end

      projected
    end

    assert {:ok, store} = Store.new(1)

    store =
      Map.merge(store, %{
        test_pid: observer,
        observed_tool: Enum.find(names, &(&1 in Filesystem.names()))
      })

    assert {:ok, occurrence} =
             Headless.start_link(
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
               work: 16,
               run_timeout: 30_000,
               effect_timeout: 15_000,
               commit_timeout: 10_000,
               cleanup_timeout: 5_000
             )

    on_exit(fn ->
      if Process.alive?(occurrence), do: GenServer.stop(occurrence, :normal, 5_000)
    end)

    %{
      occurrence: occurrence,
      session: session,
      binding: binding,
      identity: identity,
      catalog: catalog,
      store: store
    }
  end

  defp receive_outer(fixture, source) do
    assert_receive {:filesystem_context, invocation, pinned, {:ok, snapshot}, _}, 5_000
    assert invocation.tool_name == "exec"
    assert invocation.arguments == source
    assert_pinned(fixture, invocation, pinned, snapshot)
    invocation
  end

  defp receive_target(fixture, outer, name, arguments) do
    assert_receive {:filesystem_context, invocation, pinned, {:ok, snapshot}, gate}, 5_000
    assert invocation.tool_name == name
    assert invocation.arguments == arguments
    assert invocation.enclosing_invocation_id == outer.invocation_id
    assert invocation.step_id == outer.step_id
    assert invocation.attempt_id == outer.attempt_id
    assert invocation.turn_id == outer.turn_id
    assert_pinned(fixture, invocation, pinned, snapshot)
    {invocation, gate}
  end

  defp assert_pinned(fixture, invocation, pinned, snapshot) do
    assert invocation.run_id == fixture.identity.run_id
    assert invocation.incarnation == 1
    assert invocation.catalog_revision == 1
    assert invocation.tool_revision == 1
    assert pinned.revision == 1
    assert pinned.registry == fixture.catalog.registry
    assert pinned.tools == fixture.catalog.tools
    assert pinned.authority == fixture.catalog.authority
    assert snapshot.issued_descriptors == fixture.catalog.registry.tools
    assert Map.take(snapshot.scope, Map.keys(fixture.identity)) == fixture.identity
  end

  defp observe_committed_worker(fixture, outer, invocation) do
    assert_receive {:filesystem_intent_committed, input, revision, writer}, 5_000
    assert input.invocation_id == invocation.invocation_id
    assert {:ok, aggregate} = Store.load(fixture.store, fixture.identity.run_id)
    assert aggregate.revision == revision
    intent = aggregate.run.execution_intents["tool:#{invocation.invocation_id}"]
    assert intent.status == :started
    assert_intent_operation(fixture, outer, invocation, intent)
    assert Map.get(aggregate.run.tool_results, invocation.invocation_id) == nil
    assert {:ok, workers} = ResourceRegistry.worker_supervisor(fixture.binding.resource_registry)
    assert [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    assert Process.alive?(worker)
    assert {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    assert File.exists?("/proc/#{os_identity.pid}")
    observation = %{pid: worker, monitor: Process.monitor(worker), os_pid: os_identity.pid}
    send(writer, {:release_filesystem_ack, invocation.invocation_id})
    assert_receive {:filesystem_store_ack, :tool_invoked, ^revision}, 1_000
    observation
  end

  defp assert_previous_effect(root, "write") do
    assert File.ls!(root) == ["companion.txt"]
    assert File.read!(Path.join(root, "companion.txt")) == "other\n"
  end

  defp assert_previous_effect(root, "edit"),
    do: assert(File.read!(Path.join(root, "draft.txt")) == "one\nkeep\n")

  defp assert_previous_effect(root, "multi"),
    do: assert(File.read!(Path.join(root, "draft.txt")) == "two\nkeep\n")

  defp assert_previous_effect(root, "move") do
    assert File.read!(Path.join(root, "draft.txt")) == "three\nkeep\n"
    assert File.read!(Path.join(root, "companion.txt")) == "final\n"
  end

  defp assert_previous_effect(root, key) when key in ~w(list grep glob deleted) do
    assert Enum.sort(File.ls!(root)) == ["companion.txt", "moved.txt"]
    assert File.read!(Path.join(root, "moved.txt")) == "three\nkeep\n"
    assert File.read!(Path.join(root, "companion.txt")) == "final\n"
  end

  defp assert_terminal(fixture, outer, result, operations, worker) do
    assert result.status == :completed
    assert result.nested_invocations == length(operations)
    assert result.outer_reservations == 1
    assert result.output == []
    assert result.output_truncated == false
    assert {:ok, aggregate} = Store.load(fixture.store, fixture.identity.run_id)

    assert %{phase: :terminal, resource_cleanup: :confirmed, run: record} =
             Headless.status(fixture.occurrence)

    assert aggregate.run == record
    assert record.state == :completed
    assert record.context.execution_mode == :headless
    assert record.context.conversation.headless_result == result
    assert aggregate.revision == record.expected_revision
    assert_receive {:filesystem_store_ack, :finish, final_revision}, 1_000
    assert final_revision == aggregate.revision
    assert Map.get(record, :provider_attempts, %{}) == %{}
    assert map_size(record.tool_results) == length(operations) + 1
    assert map_size(record.execution_intents) == length(operations) + 1

    for {invocation, expected_result} <- operations do
      intent = record.execution_intents["tool:#{invocation.invocation_id}"]
      assert intent.status == :consumed
      assert_intent_operation(fixture, outer, invocation, intent)
      assert record.tool_results[invocation.invocation_id] == expected_result
      assert Map.get(record.tool_presentations, invocation.invocation_id) == nil
    end

    assert length(Enum.uniq(Enum.map(operations, fn {op, _} -> op.invocation_id end))) ==
             length(operations)

    assert Enum.sort(for {_, intent} <- record.execution_intents, do: intent.operation.tool_name) ==
             Enum.sort(["exec" | Enum.map(operations, fn {op, _} -> op.tool_name end)])

    outer_operation = record.execution_intents["tool:#{outer.invocation_id}"].operation
    assert outer_operation.tool_name == "exec"
    assert outer_operation.arguments == outer.arguments
    assert outer_operation.enclosing_invocation_id == outer.invocation_id
    assert outer_operation.caller == fixture.identity.caller

    assert record.tool_results[outer.invocation_id] == %{
             status: :completed,
             value: result.value,
             output: [],
             output_truncated: false,
             is_error: false
           }

    %{pid: pid, monitor: monitor, os_pid: os_pid} = worker
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    assert File.exists?("/proc/#{os_pid}") == false
    aggregate
  end

  defp assert_intent_operation(fixture, outer, invocation, intent) do
    assert intent.reservation.reservation_id == "tool:#{invocation.invocation_id}"

    assert intent.operation == %{
             run_id: fixture.identity.run_id,
             incarnation: 1,
             step_id: outer.step_id,
             attempt_id: outer.attempt_id,
             turn_id: outer.turn_id,
             invocation_id: invocation.invocation_id,
             tool_call_id: invocation.tool_call_id,
             enclosing_invocation_id: outer.invocation_id,
             tool_name: invocation.tool_name,
             tool_revision: 1,
             catalog_revision: 1,
             arguments: invocation.arguments,
             caller: fixture.identity.caller,
             effective_authority: Map.delete(fixture.catalog.authority, :grants)
           }
  end

  defp close_fixture(fixture, aggregate) do
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(fixture.session)

    assert {:ok, ^aggregate} = Store.load(fixture.store, fixture.identity.run_id)
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
