defmodule Synapsis.Agent.Tools.HeadlessCodeModeFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex

  alias Backplane.AgentRuntime.Codex.{
    CodeMode,
    Contract,
    Headless,
    ResourceRegistry,
    Session,
    Tools
  }

  alias Synapsis.Agent.Runtime.Store

  @moduletag :tmp_dir
  @selection ~w(exec wait clock::curr_time fixture_effect)
  @source """
  // @exec: {"yield_time_ms": 1}
  text("before");
  text(await tools.clock__curr_time({}));
  const effect = await tools.fixture_effect({value: input.value});
  text("between");
  store("marker", "continued");
  yield "ordinary-pause";
  text(load("marker"));
  text(await tools.clock__curr_time({}));
  text("after");
  return effect;
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

    defp observe(context, meta, {:ok, acknowledgement} = result) do
      send(
        context.test_pid,
        {:headless_store_ack, elem(meta.command, 0), acknowledgement.revision}
      )

      result
    end

    defp observe(_context, _meta, result), do: result
  end

  defmodule Effect do
    def execute(operation) do
      context = operation.backend_context
      send(context.test_pid, {:headless_effect_ready, self(), operation})

      receive do
        :release_headless_effect ->
          :ok = File.write(context.path, "run\n", [:append])
          {:ok, operation.arguments}
      after
        5_000 -> raise "ordinary Headless effect observation was not released"
      end
    end
  end

  test "native Headless completes clock and one effect across automatic continuations", %{
    tmp_dir: root
  } do
    assert :ok = Synapsis.Session.Store.ensure_started()
    assert {:ok, store} = Store.new(1)
    store = Map.put(store, :test_pid, self())
    run_id = Ecto.UUID.generate()
    path = Path.join(root, "headless-effect-count.txt")
    session = start_supervised!({Session, owner_pid: self()})

    authority = %{
      caller: "synapsis-headless-functional",
      run_id: run_id,
      grants: @selection,
      tool_revision: 1
    }

    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    effect = %{
      name: "fixture_effect",
      description: "Append one ordinary fixture effect",
      schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"],
        "additionalProperties" => false
      },
      backend: Effect,
      backend_context: %{test_pid: self(), path: path},
      revision: 1,
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    clock =
      Enum.filter(Tools.contracts(%{}), fn contract ->
        Contract.canonical_name(contract[:namespace], contract.name) == "clock::curr_time"
      end)

    assert {:ok, catalog} =
             Codex.profile(
               :code_mode_only,
               %{
                 session_binding: binding,
                 deno_path: System.find_executable("deno"),
                 code_mode_contracts: clock ++ [effect],
                 timeout: 10_000
               },
               authority,
               tools: @selection
             )

    assert catalog.registry.tools["exec"].backend == Codex.Backend
    assert catalog.registry.tools["clock::curr_time"].backend == Codex.Backend

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
               subscriber: self(),
               work: 8,
               run_timeout: 15_000,
               effect_timeout: 10_000
             )

    on_exit(fn ->
      if Process.alive?(occurrence), do: GenServer.stop(occurrence, :normal, 5_000)
    end)

    assert {:ok, %{run_id: ^run_id, incarnation: 1}} =
             Headless.execute(occurrence, @source, input: %{"value" => 42})

    assert_receive {:headless_effect_ready, effect_worker, operation}, 5_000
    assert {:ok, before_effect} = Store.load(store, run_id)
    intent = before_effect.run.execution_intents["tool:#{operation.invocation_id}"]

    identity =
      ~w(run_id incarnation invocation_id tool_name tool_revision caller catalog_revision)a

    assert Map.take(intent.operation, identity) == Map.take(operation, identity)
    assert intent.operation.tool_name == "fixture_effect"
    refute Map.has_key?(before_effect.run.tool_results, operation.invocation_id)
    refute File.exists?(path)
    assert_receive {:headless_store_ack, :host_step_started, _}, 1_000
    intent_revision = before_effect.revision
    assert_receive {:headless_store_ack, :tool_invoked, ^intent_revision}, 1_000

    # This ordinary observation gate does not force the private #140 timer /
    # generator interleaving; the upstream deterministic test is source evidence.
    assert {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    assert [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    assert Process.alive?(worker)
    assert {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    assert File.exists?("/proc/#{os_identity.pid}")
    monitor = Process.monitor(worker)
    send(effect_worker, :release_headless_effect)

    assert {:ok, result} = Headless.await(occurrence, timeout: 10_000)
    assert result.status == :completed
    assert result.value == %{"value" => 42}
    assert result.nested_invocations == 3
    assert result.outer_reservations == 1
    assert result.output_truncated == false
    assert [before, first_clock, between, continued, second_clock, after_output] = result.output
    assert before == %{"type" => "text", "text" => "before"}
    assert between == %{"type" => "text", "text" => "between"}
    assert continued == %{"type" => "text", "text" => "continued"}
    assert after_output == %{"type" => "text", "text" => "after"}

    for clock_output <- [first_clock, second_clock] do
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
    assert_receive {:headless_store_ack, :finish, revision}, 1_000
    assert revision == aggregate.revision
    assert map_size(record.tool_results) == 4
    assert record.tool_results[operation.invocation_id] == %{"value" => 42, is_error: false}

    names = for {_, intent} <- record.execution_intents, do: intent.operation.tool_name
    assert Enum.sort(names) == ~w(clock::curr_time clock::curr_time exec fixture_effect)
    assert File.read!(path) == "run\n"
    refute_receive {:headless_effect_ready, _, _}, 0
    refute_receive {:headless_store_ack, :provider_started, _}, 0
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    refute File.exists?("/proc/#{os_identity.pid}")
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} = Session.status(session)
    assert {:ok, ^aggregate} = Store.load(store, run_id)
    assert File.read!(path) == "run\n"
  end
end
