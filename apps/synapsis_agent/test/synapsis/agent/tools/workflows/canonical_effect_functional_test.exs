defmodule Synapsis.Agent.Tools.Workflows.CanonicalEffectFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{RunInventory, SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.{Effect, Journal}
  alias Synapsis.Filesystem.Local
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store, as: SessionStore
  alias Synapsis.Workflow.Continuations

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @caller_tool "fixture_canonical_workflow"
  @names ~w(exec wait synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @trace_targets [
    {Effect, :run, 2},
    {Filesystem, :execute, 1},
    {Filesystem, :validate_prepared_receipt, 2},
    {Local, :prepare_target, 5},
    {Profiles, :build, 4},
    {Headless, :start_link, 1},
    {Headless, :execute, 3},
    {Session, :start_link, 1},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {CodeMode.Worker, :os_identity, 1},
    {Continuations, :commit, 5}
  ]

  # This wrapper holds the genuine issued Profiles snapshot and delegates the
  # production handlers unchanged. Copies of returned states are observation
  # only: no prepared record, ticket, operation or authority is manufactured.
  # It does not exercise Worker/options admission or a production Workflow caller.
  defmodule AdapterHost do
    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    def init(observer) do
      {:ok,
       %{
         observer: observer,
         closing: false,
         error: nil,
         tool_contexts: %{},
         jobs: %{},
         owner_ref: Process.monitor(observer)
       }}
    end

    def handle_call({:install_root, key, snapshot}, _from, state) do
      entry = %{
        snapshot: snapshot,
        discovery: nil,
        prepared_targets: %{},
        prepared_target_bytes: 0,
        prepared_targets_closed?: false
      }

      {:reply, :ok, %{state | tool_contexts: %{key => entry}}}
    end

    def handle_call({:root_snapshot, key}, _from, state),
      do: {:reply, state.tool_contexts[key].snapshot, state}

    def handle_call(message, from, state) do
      {:reply, result, next} = SessionAdapter.handle_call(message, from, state)
      send(state.observer, {:adapter_call, message, elem(from, 0), result, next.tool_contexts})
      {:reply, result, next}
    end

    def handle_info(message, state) do
      {:noreply, next} = SessionAdapter.handle_info(message, state)
      {:noreply, next}
    end
  end

  # The only custom tool is this original fixture caller. Its operation and
  # binding are admitted by the real native parent. The trusted capability is
  # constructed by the same internal SessionAdapter API used by production.
  defmodule CallerBackend do
    def execute(operation) do
      context = operation.backend_context
      observer = context.observer
      trace(observer)
      key = {operation.run_id, operation.incarnation}
      snapshot = GenServer.call(context.adapter, {:root_snapshot, key}, 5_000)

      supplied =
        context
        |> Map.take([
          :session_binding,
          :profiles_context,
          :ceiling,
          :store,
          :session_id,
          :caller,
          :workflow_effect_registration
        ])
        |> Map.put(:profiles_snapshot, snapshot)
        |> Map.put(:operation, operation)

      before_parent = parent_state(operation)
      scenario = Map.fetch!(context.scenarios, operation.arguments["key"])

      {request, result, record} =
        if context.mode == :journal do
          {:ok, initial} = Journal.create(supplied)
          request = put_in(scenario.request, [:correlation, :workflow_id], initial.id)
          result = Journal.run(initial, request, supplied)
          {request, result, initial}
        else
          {scenario.request, Effect.run(scenario.request, supplied), nil}
        end

      after_parent = parent_state(operation)
      drain_trace()
      :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])

      send(
        observer,
        {:canonical_outcome, self(), operation, request, result, record, before_parent,
         after_parent}
      )

      case result do
        {:ok, %{effect: effect}} -> {:ok, %{value: effect.consumer_value, is_error: false}}
        {:ok, effect} -> {:ok, %{value: effect.consumer_value, is_error: false}}
        error -> error
      end
    end

    def trace(observer),
      do: :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

    def drain_trace do
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "canonical Workflow trace did not drain"
      end
    end

    defp parent_state(operation) do
      context = operation.backend_context

      %{
        owner: context.resource_owner_pid,
        owner_alive: Process.alive?(context.resource_owner_pid),
        session_alive: Process.alive?(context.session_binding.session),
        validation: Session.validate(context.session_binding, operation)
      }
    end
  end

  test "ordinary local canonical effects preserve projection, literal paths and child ownership",
       %{
         tmp_dir: root
       } do
    files = Path.join(root, "files")
    File.mkdir!(files)
    File.write!(Path.join(files, "input.txt"), "input\n")
    File.write!(Path.join(files, "edit.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(files, "@literal.txt"), "literal\n")
    scenarios = scenarios("", ".", true)
    fixture = open_fixture(root, root, scenarios, :effect)
    {outcomes, events} = exercise(fixture, scenarios)
    assert File.read!(Path.join(files, "input.txt")) == "input\n"
    assert File.read!(Path.join(files, "write.txt")) == "new\n"
    assert File.read!(Path.join(files, "edit.txt")) == "beta\nBETA\ngamma\n"
    assert File.read!(Path.join(files, "@literal.txt")) == "literal\n"
    assert_children(fixture, scenarios, outcomes, events)
    assert_retained(fixture, outcomes)
  end

  test "ordinary Workspace Journal effects settle and fresh readers retain exact native evidence",
       %{
         tmp_dir: root
       } do
    workspace = Path.join(root, "workspace")
    session_id = Ecto.UUID.generate()
    agent_name = "canonical-workflow-" <> session_id
    directory = "@synapsis/agents/#{agent_name}/sessions/#{session_id}/files"
    shared = Path.join(workspace, String.replace_prefix(directory, "@synapsis/", ""))
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, "input.txt"), "input\n")
    File.write!(Path.join(shared, "edit.txt"), "alpha\nbeta\ngamma\n")
    scenarios = scenarios(directory <> "/", directory, false)
    fixture = open_fixture(root, workspace, scenarios, :journal, session_id)
    {outcomes, events} = exercise(fixture, scenarios)
    assert File.read!(Path.join(shared, "input.txt")) == "input\n"
    assert File.read!(Path.join(shared, "write.txt")) == "new\n"
    assert File.read!(Path.join(shared, "edit.txt")) == "beta\nBETA\ngamma\n"
    assert_children(fixture, scenarios, outcomes, events)

    for outcome <- outcomes do
      %{record: record, effect: effect} = outcome.result
      assert outcome.initial.revision == 1
      assert outcome.initial.snapshot["effects"] == []
      assert record.revision == 3
      assert [entry] = record.snapshot["effects"]
      assert entry["state"] == "settled"
      assert entry["pending_revision"] == 2
      assert entry["settled_revision"] == 3

      {pending_index, pending_pid, [session_id, workflow_id, 1, pending, _]} =
        one_call(events, Continuations, :commit, fn [_, id, revision, _, _] ->
          id == record.id and revision == 1
        end)

      assert session_id == fixture.identity.session_id
      assert workflow_id == record.id
      assert [pending_entry] = pending["effects"]
      assert pending_entry["state"] == "pending"
      assert pending_entry["request"] === entry["request"]

      assert {:ok, acknowledged} =
               return_after(events, pending_index, pending_pid, {Continuations, :commit, 5})

      assert acknowledged.revision == 2
      assert acknowledged.snapshot === pending
      assert_fresh_reopen(fixture, outcome)
      reference = entry["receipt"]

      assert {:ok, fact} =
               RuntimeStore.get_fact(session_id, :workflow_effect_receipt, reference["fact_id"])

      assert fact.effect === effect
      assert {:ok, aggregate} = Store.load(fixture.store, effect.locator.run_id)
      assert aggregate.revision == reference["final_revision"]

      assert aggregate.run.tool_results[effect.receipt.target_intent.operation.invocation_id] ===
               effect.receipt.target_result
    end

    assert_retained(fixture, outcomes)
  end

  defp scenarios(prefix, directory, literal?) do
    read = %{"path" => prefix <> "input.txt"}
    write = %{"path" => prefix <> "write.txt", "content" => "new\n"}

    raw_edit = %{
      "path" => prefix <> "edit.txt",
      "edits" => ~s([{"oldText":"alpha","newText":"beta","metadata":"discard"}]),
      "oldText" => "beta",
      "newText" => "BETA",
      "metadata" => "discard"
    }

    prepared_edit = %{
      "path" => prefix <> "edit.txt",
      "edits" => [
        %{"oldText" => "alpha", "newText" => "beta"},
        %{"oldText" => "beta", "newText" => "BETA"}
      ]
    }

    write_result = %{
      content: [%{type: "text", text: "Successfully wrote 4 bytes to " <> prefix <> "write.txt"}],
      details: %{
        diff: "+1 new",
        firstChangedLine: 1,
        patch: "--- #{prefix}write.txt\n+++ #{prefix}write.txt\n@@ -0,0 +1,1 @@\n+new\n",
        changed: true,
        created: true
      },
      is_error: false
    }

    edit_result = %{
      content: [
        %{type: "text", text: "Successfully replaced 2 block(s) in " <> prefix <> "edit.txt."}
      ],
      details: %{
        diff: "-1 alpha\n 1 beta\n+2 BETA\n 3 gamma",
        firstChangedLine: 1,
        patch:
          "--- #{prefix}edit.txt\n+++ #{prefix}edit.txt\n@@ -1,3 +1,3 @@\n-alpha\n beta\n+BETA\n gamma\n",
        changed: true
      },
      is_error: false
    }

    listing =
      if literal?,
        do: "\"@literal.txt\"\n\"edit.txt\"\n\"input.txt\"\n\"write.txt\"",
        else: "\"edit.txt\"\n\"input.txt\"\n\"write.txt\""

    base = [
      scenario("read", "synapsis::read", read, read, text_result("input\n")),
      scenario("write", "synapsis::write", write, write, write_result),
      scenario("edit", "synapsis::edit", raw_edit, prepared_edit, edit_result),
      scenario("ls", "synapsis::ls", %{"path" => directory}, %{"path" => directory}, %{
        content: [%{type: "text", text: listing}],
        details: %{content: listing},
        is_error: false
      })
    ]

    if literal? do
      # An @ path at the beginning is eligible for the source's ./ preservation.
      base ++
        [
          scenario(
            "literal",
            "synapsis::read",
            %{"path" => "@literal.txt"},
            %{
              "path" => "./@literal.txt"
            },
            text_result("literal\n")
          )
        ]
    else
      base
    end
  end

  defp scenario(key, name, raw, prepared, expected) do
    %{
      key: key,
      prepared: prepared,
      expected: expected,
      request: %{
        correlation: %{workflow_id: Ecto.UUID.generate(), request_id: key, segment: 0},
        target: %{tool_name: name, tool_revision: 1, arguments: raw},
        limits: %{
          timeout_ms: 20_000,
          effect_timeout_ms: 15_000,
          commit_timeout_ms: 5_000,
          cleanup_timeout_ms: 5_000,
          output_limit: 65_536,
          work: 4
        }
      }
    }
  end

  defp open_fixture(root, workspace, scenarios, mode, session_id \\ nil) do
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    session_id = session_id || Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    all_names = @names ++ [@caller_tool]
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "canonical-workflow-#{session_id}",
               enabled: true,
               tools: @names,
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
      cleanup_journal(session_id, store.namespace)
    end)

    identity = %{
      caller: caller,
      session_id: session_id,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    ceiling = %{
      caller: caller,
      run_id: run_id,
      grants: all_names,
      tool_revision: 1,
      tool_revisions: Map.new(all_names, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 5_000})
    assert {:ok, binding} = Session.bind(session, ceiling, incarnation: 1)
    assert {:ok, native} = HostCodeMode.bundles(%{session_binding: binding}, ceiling, @names)
    adapter = start_supervised!({AdapterHost, self()})

    fetch = fn invocation, catalog, digest ->
      GenServer.call(adapter, {:filesystem_target_fetch, invocation, catalog, digest}, 5_000)
    end

    project = if mode == :effect, do: Path.join(root, "files"), else: root

    profiles_context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{id: agent.id, name: agent.name, tools: @names, tool_contract_version: 1},
      project_path: project,
      tool_filesystem: %{
        path_environment: %{
          cwd: root,
          os_home: Path.join(root, "home"),
          platform: :linux,
          workspace_root: workspace
        },
        prepared_target_resolver: fetch,
        execution_options: [
          node_executable: @node,
          model_budget: nil,
          model_has_vision: true,
          auto_resize_images: true
        ]
      }
    }

    # The local fixture uses cwd=root/files so every local path, including the
    # literal @ path, resolves in this fixture's contained directory.
    profiles_context =
      if mode == :effect,
        do: put_in(profiles_context.tool_filesystem.path_environment.cwd, project),
        else: profiles_context

    assert {:ok, %{bundle: original, snapshot: snapshot}} =
             Profiles.build(profiles_context, identity, native, ceiling)

    registration = SessionAdapter.workflow_effect_registration(adapter, run_id, 1)

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: CallerBackend,
      backend_context: %{
        observer: self(),
        adapter: adapter,
        mode: mode,
        scenarios: Map.new(scenarios, &{&1.key, &1}),
        workflow_effect_registration: registration,
        session_binding: binding,
        profiles_context: profiles_context,
        ceiling: ceiling,
        store: store,
        session_id: session_id,
        caller: caller
      },
      schema: %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}},
        "required" => ["key"],
        "additionalProperties" => false
      },
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, catalog} = Catalog.compose([original], [descriptor], ceiling, all_names)
    # Only the custom caller extends the actual issued catalog. Profiles then
    # derives its exact binding through the existing pure projection API.
    snapshot = %{snapshot | issued_descriptors: catalog.registry.tools}
    pinned = Map.put(Map.take(catalog, [:registry, :tools, :authority]), :revision, 1)
    assert {:ok, snapshot} = Profiles.project_catalog(identity, snapshot, pinned)
    assert :ok = GenServer.call(adapter, {:install_root, {run_id, 1}, snapshot}, 5_000)

    options = [
      run_id: run_id,
      incarnation: 1,
      session_binding: binding,
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      store: Store,
      context: store,
      subscriber: self(),
      work: 12,
      run_timeout: 90_000,
      effect_timeout: 70_000,
      commit_timeout: 5_000,
      cleanup_timeout: 5_000
    ]

    assert {:ok, parent} = Headless.start_link(options)
    on_exit(fn -> if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000) end)

    %{
      parent: parent,
      session: session,
      binding: binding,
      identity: identity,
      adapter: adapter,
      snapshot: snapshot,
      profiles_context: profiles_context,
      store: store,
      mode: mode
    }
  end

  defp exercise(fixture, scenarios) do
    install_observation()

    source =
      "// @exec: {\"yield_time_ms\": 10000}\nconst values = [];\n" <>
        Enum.map_join(scenarios, "\n", fn scenario ->
          "values.push((await tools.fixture_canonical_workflow({key: #{Jason.encode!(scenario.key)}})).value);"
        end) <> "\nreturn values;\n"

    assert {:ok, %{run_id: run_id}} = Headless.execute(fixture.parent, source)
    assert run_id == fixture.identity.run_id

    outcomes =
      for scenario <- scenarios do
        assert_receive {:canonical_outcome, owner, operation, request, {:ok, result}, initial,
                        before_parent, after_parent},
                       40_000

        assert operation.arguments === %{"key" => scenario.key}
        assert before_parent === after_parent
        assert before_parent.owner == fixture.parent
        assert before_parent.owner_alive
        assert before_parent.session_alive
        assert {:ok, _} = before_parent.validation
        effect = if fixture.mode == :journal, do: result.effect, else: result

        %{
          owner: owner,
          operation: operation,
          request: request,
          result: result,
          initial: initial,
          effect: effect
        }
      end

    assert {:ok, result} = Headless.await(fixture.parent, timeout: 20_000)
    assert result.status == :completed
    assert result.value === Enum.map(outcomes, & &1.effect.consumer_value)
    assert result.nested_invocations == length(scenarios)
    assert result.output == []
    assert result.output_truncated == false
    assert Process.alive?(fixture.parent)
    assert Process.alive?(fixture.session)
    assert Map.keys(:sys.get_state(fixture.adapter).tool_contexts) == [{run_id, 1}]
    assert {:ok, aggregate} = Store.load(fixture.store, run_id)
    assert aggregate.run.state == :completed
    assert Map.get(aggregate.run, :provider_attempts, %{}) == %{}
    {outcomes, drain_observation([])}
  end

  defp assert_children(fixture, scenarios, outcomes, events) do
    assert length(Enum.uniq_by(outcomes, & &1.effect.locator.run_id)) == length(outcomes)

    assert length(Enum.uniq_by(outcomes, & &1.effect.retirement.resource_handle)) ==
             length(outcomes)

    effect_calls = for {:trace, _, :call, {Effect, :run, _}} <- events, do: :called
    assert length(effect_calls) == length(outcomes)
    selections = for {:trace, _, :call, {Local, :prepare_target, _}} <- events, do: :selected
    assert length(selections) == if(fixture.mode == :effect, do: length(outcomes), else: 0)

    callbacks =
      for {scenario, outcome} <- Enum.zip(scenarios, outcomes) do
        assert_effect(fixture, scenario, outcome, events)
      end

    for field <- [:reserve, :seal, :fetch, :abandon] do
      assert length(Enum.uniq(Enum.map(callbacks, &Map.fetch!(&1, field)))) == length(callbacks)
    end
  end

  defp assert_effect(fixture, scenario, outcome, events) do
    effect = outcome.effect
    run_id = effect.locator.run_id
    key = {run_id, 1}
    parent_key = {fixture.identity.run_id, 1}
    target_name = scenario.request.target.tool_name
    names = ["exec", "wait", target_name]
    assert effect.request === outcome.request
    assert effect.locator.effect_request === outcome.request
    assert effect.locator.parent_run_id == fixture.identity.run_id
    assert effect.locator.parent_invocation_id == outcome.operation.invocation_id
    assert effect.consumer_value === json_value(Map.delete(scenario.expected, :is_error))
    assert {:ok, aggregate} = Store.load(fixture.store, run_id)
    receipt = effect.receipt
    record = aggregate.run
    outer = receipt.outer_intent.operation
    target = receipt.target_intent.operation
    assert record.state == :completed
    assert map_size(record.execution_intents) == 2
    assert map_size(record.tool_results) == 2
    assert Map.get(record, :provider_attempts, %{}) == %{}
    assert receipt.final_revision == aggregate.revision

    assert receipt === %{
             version: 1,
             run_id: run_id,
             incarnation: 1,
             turn_id: outer.turn_id,
             catalog_revision: 1,
             catalog_digest: record.context.headless_catalog["descriptor_digest"],
             outer_intent: record.execution_intents["tool:#{outer.invocation_id}"],
             target_intent: record.execution_intents["tool:#{target.invocation_id}"],
             target_result: scenario.expected,
             target_presentation: nil,
             final_revision: aggregate.revision
           }

    assert receipt.target_result === scenario.expected
    assert receipt.target_intent.status == :consumed
    assert receipt.outer_intent.status == :consumed
    assert receipt.target_intent === record.execution_intents["tool:#{target.invocation_id}"]
    assert receipt.outer_intent === record.execution_intents["tool:#{outer.invocation_id}"]
    assert target.arguments === scenario.prepared

    if scenario.key in ["edit", "literal"],
      do: assert(target.arguments !== outcome.request.target.arguments)

    assert target.tool_name == target_name
    assert target.run_id == run_id
    assert target.enclosing_invocation_id == outer.invocation_id

    for field <- [
          :run_id,
          :incarnation,
          :turn_id,
          :step_id,
          :attempt_id,
          :catalog_revision,
          :caller
        ],
        do: assert(target[field] === outer[field])

    assert outer.arguments === @source
    assert record.tool_results[target.invocation_id] === scenario.expected
    assert record.context.conversation.headless_result.value === effect.consumer_value
    assert record.context.conversation.headless_result.nested_invocations == 1
    assert record.context.conversation.headless_result.outer_reservations == 1

    {build_index, build_pid, [context, identity, _, _]} =
      one_call(events, Profiles, :build, fn [_, identity, _, _] -> identity.run_id == run_id end)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             return_after(events, build_index, build_pid, {Profiles, :build, 4})

    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(names)
    assert snapshot.issued_descriptors === bundle.registry.tools
    assert snapshot.permission === fixture.snapshot.permission
    assert snapshot.evidence === fixture.snapshot.evidence
    assert identity.session_id == fixture.identity.session_id

    assert [{register_message, owner, {:ok, ticket}, reserved}] =
             adapter_calls(events, :workflow_effect_register, fn message ->
               elem(message, 3).run_id == run_id
             end)

    assert owner == outcome.owner

    assert elem(register_message, 2).catalog ===
             outcome.operation.backend_context.catalog_snapshot

    assert elem(register_message, 2).authority === outcome.operation.effective_authority
    assert reserved[key].workflow.phase == :pending
    assert reserved[key].prepared_targets == %{}
    assert reserved[key].prepared_targets_closed?
    assert reserved[parent_key].snapshot === fixture.snapshot
    assert context.tool_filesystem === ticket.tool_filesystem

    assert [{_, ^owner, {:ok, host_context}, active}] =
             adapter_calls(events, :workflow_effect_activate, fn message ->
               elem(message, 1) == key
             end)

    assert active[key].snapshot === snapshot
    assert active[key].workflow.owner == owner
    assert active[key].workflow.phase == :active
    assert active[key].prepared_targets == %{}
    assert active[key].prepared_targets_closed? == false
    assert host_context.filesystem_preparation === ticket.preparation
    child_descriptor = bundle.registry.tools[target_name]
    parent_descriptor = fixture.snapshot.issued_descriptors[target_name]

    expected_context =
      parent_descriptor.backend_context
      |> Map.merge(%{run_id: run_id, incarnation: 1, catalog_revision: 1})
      |> Map.put(:prepared_target_resolver, ticket.preparation.fetch)

    assert child_descriptor === %{parent_descriptor | backend_context: expected_context}
    assert child_descriptor.backend_context.prepared_target_resolver === ticket.preparation.fetch
    assert ticket.preparation.fetch !== parent_descriptor.backend_context.prepared_target_resolver

    assert [{_, _, {:ok, prepared_record}, sealed}] =
             adapter_calls(events, :filesystem_target_seal, fn message ->
               elem(message, 1).run_id == run_id
             end)

    assert Map.keys(sealed) |> Enum.sort() == Enum.sort([parent_key, key])
    assert sealed[parent_key].prepared_targets == %{}
    assert map_size(sealed[key].prepared_targets) == 1
    assert [{ledger_key, envelope}] = Map.to_list(sealed[key].prepared_targets)
    assert envelope.state == :sealed
    assert envelope.record === prepared_record

    assert ledger_key ===
             {run_id, 1, 1, target.invocation_id, target_name, target.tool_revision}

    assert prepared_record.key === ledger_key
    assert prepared_record.raw_arguments_digest === digest(outcome.request.target.arguments)
    assert prepared_record.prepared_arguments_digest === digest(scenario.prepared)
    assert prepared_record.public_path === scenario.prepared["path"]
    assert prepared_record.original_path === outcome.request.target.arguments["path"]

    if fixture.mode == :journal do
      logical = String.replace_prefix(scenario.prepared["path"], "@synapsis", "")
      assert prepared_record.target === {:workspace, logical}
      assert prepared_record.resource == "workspace:" <> logical
      assert prepared_record.requested_absolute == nil
    else
      relative = if scenario.key == "literal", do: "@literal.txt", else: scenario.prepared["path"]
      absolute = Path.expand(relative, fixture.profiles_context.project_path)
      relative = if scenario.key == "ls", do: ".", else: relative
      assert prepared_record.target === {:local, absolute, relative}
      assert prepared_record.resource == "filesystem:" <> absolute
    end

    fetches =
      adapter_calls(events, :filesystem_target_fetch, fn message ->
        elem(message, 1).run_id == run_id
      end)

    assert fetches != []

    for {_, _, response, state} <- fetches do
      assert response === {:ok, prepared_record}
      assert state[key].prepared_targets[ledger_key].record === prepared_record
      assert state[parent_key].prepared_targets == %{}
    end

    {receipt_index, receipt_pid, [raw, live_operation]} =
      one_call(events, Filesystem, :validate_prepared_receipt, fn [_, operation] ->
        operation.run_id == run_id
      end)

    assert raw === outcome.request.target.arguments
    assert live_operation.arguments === scenario.prepared
    assert live_operation.backend_context.prepared_target_resolver === ticket.preparation.fetch

    assert return_after(
             events,
             receipt_index,
             receipt_pid,
             {Filesystem, :validate_prepared_receipt, 2}
           ) ===
             :ok

    {_, _, [executed]} =
      one_call(events, Filesystem, :execute, fn [operation] ->
        operation.run_id == run_id
      end)

    assert executed.arguments === scenario.prepared

    {start_index, start_pid, [options]} =
      one_call(events, Headless, :start_link, fn [options] -> options[:run_id] == run_id end)

    assert {:ok, child} = return_after(events, start_index, start_pid, {Headless, :start_link, 1})
    assert options[:hooks] == Policy
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority
    assert options[:host_context] === host_context
    assert options[:session_binding] === active[key].workflow.binding
    assert options[:session_binding].session != fixture.session
    assert options[:session_binding].resource_registry != fixture.binding.resource_registry
    assert Keyword.has_key?(options, :provider) == false

    {_, _, [^child, @source, execution]} =
      one_call(events, Headless, :execute, fn [pid, _, _] -> pid == child end)

    assert execution === [input: %{"tool_name" => target_name, "arguments" => raw}]
    registry = fixture.binding.resource_registry
    handle = effect.retirement.resource_handle

    {release_index, release_pid, [^registry, ^handle, owner_id]} =
      one_call(events, ResourceRegistry, :release, fn [r, h, _] ->
        r == registry and h == handle
      end)

    assert owner_id == fixture.binding.owner_id
    assert receipt_index < release_index

    assert return_after(events, release_index, release_pid, {ResourceRegistry, :release, 3}) ===
             {:ok, :ok}

    assert effect.retirement === %{
             resource_handle: handle,
             release: :confirmed,
             headless: :normal,
             session: :normal,
             registry: :normal
           }

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, owner_id)

    for pid <- [
          child,
          options[:session_binding].session,
          options[:session_binding].resource_registry
        ] do
      assert Enum.any?(events, &match?({:trace, ^pid, :exit, :normal}, &1))
      assert Process.alive?(pid) == false
    end

    child_registry = options[:session_binding].resource_registry

    {_, _, [^child_registry, _, :continuation, worker, _]} =
      one_call(events, ResourceRegistry, :register, fn [r, _, kind, _, _] ->
        r == child_registry and kind == :continuation
      end)

    assert Enum.any?(events, &match?({:trace, ^worker, :exit, :normal}, &1))
    assert Process.alive?(worker) == false

    identities =
      for {{:trace, caller, :call, {CodeMode.Worker, :os_identity, [^worker]}}, index} <-
            Enum.with_index(events) do
        assert {:ok, identity} =
                 return_after(events, index, caller, {CodeMode.Worker, :os_identity, 1})

        identity
      end

    assert [os_identity, same_identity] = identities
    assert os_identity === same_identity
    assert File.exists?("/proc/#{os_identity.pid}") == false

    assert [{_, _, :ok, released}] =
             adapter_calls(events, :workflow_effect_release, fn message ->
               elem(message, 1) == key
             end)

    assert Map.keys(released) == [parent_key]
    assert released[parent_key].snapshot === fixture.snapshot
    assert released[parent_key].prepared_targets == %{}
    assert released[parent_key].prepared_targets_closed? == false
    ticket.preparation
  end

  defp assert_fresh_reopen(fixture, outcome) do
    %{record: record, effect: effect} = outcome.result
    assert Process.alive?(outcome.owner) == false

    assert Map.keys(:sys.get_state(fixture.adapter).tool_contexts) == [
             {fixture.identity.run_id, 1}
           ]

    assert {:ok, before} = Store.load(fixture.store, effect.locator.run_id)
    observer = self()

    task =
      Task.async(fn ->
        CallerBackend.trace(observer)

        result =
          Journal.reopen(record.session_id, record.agent_id, record.id, record.revision,
            deadline: System.monotonic_time(:millisecond) + 15_000
          )

        CallerBackend.drain_trace()
        :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])
        {self(), result}
      end)

    assert {reader, {:ok, reopened}} = Task.await(task, 20_000)
    assert reader != outcome.owner
    assert reopened.record === record
    assert [%{state: :settled, effect: ^effect}] = reopened.entries
    assert {:ok, ^before} = Store.load(fixture.store, effect.locator.run_id)
    events = drain_observation([])

    assert Enum.filter(events, fn
             {:trace, _, :call, {module, function, _}} ->
               {module, function} in [
                 {Effect, :run},
                 {Filesystem, :execute},
                 {Local, :prepare_target},
                 {Profiles, :build},
                 {Headless, :start_link},
                 {Headless, :execute}
               ]

             {:adapter_call, _, _, _, _} ->
               true

             _ ->
               false
           end) == []
  end

  defp assert_retained(fixture, outcomes) do
    before =
      Map.new(outcomes, fn %{effect: effect} ->
        assert {:ok, aggregate} = Store.load(fixture.store, effect.locator.run_id)
        {effect.locator.run_id, aggregate}
      end)

    assert {:ok, %{coverage: :retained_only, entries: entries}} =
             RunInventory.load(fixture.identity.session_id)

    assert length(entries) == length(outcomes)

    for entry <- entries do
      assert entry.availability == :present
      assert entry.aggregate === before[entry.locator.run_id]
    end

    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)

    for {run_id, aggregate} <- before,
        do: assert(Store.load(fixture.store, run_id) === {:ok, aggregate})

    assert {:ok, %{entries: ^entries}} = RunInventory.load(fixture.identity.session_id)
  end

  defp install_observation do
    for {module, _, _} = mfa <- @trace_targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    on_exit(fn -> for mfa <- @trace_targets, do: :erlang.trace_pattern(mfa, false, [:local]) end)
  end

  defp drain_observation(acc) do
    receive do
      event when is_tuple(event) and elem(event, 0) in [:trace, :adapter_call] ->
        drain_observation([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp adapter_calls(events, action, predicate) do
    for {:adapter_call, message, owner, result, state} <- events,
        elem(message, 0) == action and predicate.(message),
        do: {message, owner, result, state}
  end

  defp one_call(events, module, function, predicate) do
    matches =
      for {{:trace, pid, :call, {^module, ^function, args}}, index} <- Enum.with_index(events),
          predicate.(args),
          do: {index, pid, args}

    assert [one] = matches
    one
  end

  defp return_after(events, index, pid, mfa) do
    assert {:trace, ^pid, :return_from, ^mfa, value} =
             events
             |> Enum.drop(index + 1)
             |> Enum.find(fn
               {:trace, ^pid, :return_from, ^mfa, _} -> true
               _ -> false
             end)

    value
  end

  defp text_result(text),
    do: %{
      content: [%{type: "text", text: text}],
      details: %{kind: "text", content: text},
      is_error: false
    }

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp cleanup_journal(session_id, namespace) do
    for prefix <- [
          "coord/runtime/facts/" <> segment(session_id) <> "/",
          "coord/runtime/runs/" <> segment(namespace) <> "/",
          "coord/workflow_continuations/" <> session_id <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
