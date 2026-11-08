defmodule Synapsis.Agent.Tools.Workflows.UTF16ImportKeyDriverFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Agent.Tools.{Catalog, CodeMode}
  alias Synapsis.Agent.Tools.Workflows.Segment
  alias Synapsis.Session.Store, as: SessionStore
  alias Synapsis.Workflow.{Continuations, Schema, Value}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../../../..", __DIR__)
  @caller "fixture_utf16_import_key_driver"
  @names ["exec", "wait", @caller]
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn (await tools.fixture_utf16_import_key_driver({})).value;\n"
  @moduletag timeout: 180_000
  @targets [
    {Continuations, :create, 4},
    {Continuations, :commit, 5},
    {Continuations, :load, 3},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {Schema, :advance_pending, 3},
    {PortSession, :fulfill, 4},
    {PortSession, :close, 1}
  ]

  # This descriptor is only a genuinely admitted internal caller. No production
  # Worker/model entry or public Workflow catalog is represented by this test.
  defmodule CallerBackend do
    def execute(operation) do
      context = Map.put(operation.backend_context, :operation, operation)
      observer = context.observer
      :erlang.trace(self(), true, [:call, {:tracer, observer}])

      result =
        case context.action do
          {:run, 1, pipeline} ->
            Segment.run(pipeline, context)

          {:run, 2, pipeline} ->
            Segment.run_effects(pipeline, context, adapters())

          {:resume, 1, id, revision, json} ->
            Segment.resume(id, revision, json, context)

          {:resume, 2, id, revision, json} ->
            Segment.resume_effects(id, revision, json, context, adapters())
        end

      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "ordinary Segment observation did not drain"
      end

      :erlang.trace(self(), false, [:call])
      send(observer, {:segment_outcome, self(), operation, result})

      case result do
        {:ok, outcome} -> {:ok, %{value: outcome.envelope, is_error: false}}
        error -> error
      end
    end

    defp adapters do
      %{
        request: fn _request, _record -> raise "no native effect in UTF16 import corpus" end,
        response_json: fn _effect -> raise "no native effect in UTF16 import corpus" end
      }
    end
  end

  # Actual admitted internal caller only: arbitrary user data stays in the
  # durable tagged heap; the unchanged public envelope receives ordinary JSON
  # text from the existing template filter. No public activation is claimed.
  @high %{"type" => "string", "utf16le" => "Pdg="}
  @low %{"type" => "string", "utf16le" => "AN4="}
  @response ~S({"\ud83d":"\ude00","Pdg=":"ordinary","nested":{"\ude00":"\ud83d"}})
  @projection "{\n  \"\\ud83d\": \"\\ude00\",\n  \"Pdg=\": \"ordinary\",\n  \"nested\": {\n    \"\\ude00\": \"\\ud83d\"\n  }\n}"
  @claim_same [
    ["compile_schema", "resume_metadata"],
    ["compile_schema", "saved_response"],
    ["validate_response", "saved_response"]
  ]
  @claim_next [["compile_schema", "saved_response"], ["validate_response", "saved_response"]]

  test "admitted v1/v2 same/next durable checkpoints resume raw lone names in fresh native roots" do
    install_observation()
    assert :ok = SessionStore.ensure_started()

    for version <- [1, 2], {mode, flag} <- [{"same_stage", ""}, {"next_stage", " --emit"}] do
      root = Path.join(System.tmp_dir!(), "synapsis-utf16-key-driver-" <> Ecto.UUID.generate())
      File.mkdir_p!(root)
      scope = %{"project_root" => root, "cwd" => "."}

      pipeline =
        "ask --prompt Review --schema '{\"type\":\"object\"}'" <>
          flag <> " | template --text '{{. | json}}'"

      session_id = Ecto.UUID.generate()

      assert {:ok, agent} =
               Synapsis.AgentConfigs.create(%{
                 name: "utf16-key-#{session_id}",
                 enabled: true,
                 tools: ["exec", "wait"],
                 tool_contract_version: 1,
                 permission_mode: "yolo"
               })

      assert {:ok, store} = Store.new(1)

      on_exit(fn ->
        SessionStore.delete_session(session_id)
        Synapsis.AgentConfigs.delete(agent)
        cleanup(session_id, store.namespace)
        File.rm_rf!(root)
      end)

      first = open_root(session_id, agent, store, {:run, version, pipeline}, root, scope)
      {initial, initial_events, initial_owner} = exercise(first)
      assert initial.record.revision == 2
      assert initial.record.snapshot["revision"] == 2
      assert initial.record.snapshot["version"] == version
      assert initial.record.snapshot["machine"]["checkpoint"]["mode"] == mode
      assert initial.record.snapshot["machine"]["checkpoint"]["stage_index"] == 0

      assert initial.record.snapshot["journal"] == %{
               "kind" => "workflow",
               "version" => 1,
               "effects" => []
             }

      assert initial.envelope["status"] == "needs_input"
      assert initial.envelope["requiresInput"]["responseSchema"] == %{"type" => "object"}
      assert {:ok, retained} = Continuations.load(session_id, initial.record.id)
      assert retained === initial.record
      assert retained.snapshot === Jason.decode!(Jason.encode!(retained.snapshot))

      expected_before =
        [["compile_schema", "ask_constructor"]] ++
          if(mode == "same_stage", do: [["compile_schema", "request_metadata"]], else: [])

      assert requests(initial_events) == expected_before
      assert [{_, {:ok, created}}] = returns(initial_events, Continuations, :create, 4)
      assert created.revision == 1
      assert [{_, {:ok, boundary}}] = returns(initial_events, Continuations, :commit, 5)
      assert boundary === retained
      assert_retirement(first, initial, initial_events)
      close_root(first)
      refute Process.alive?(initial_owner)

      second =
        open_root(
          session_id,
          agent,
          store,
          {:resume, version, retained.id, 2, @response},
          root,
          scope
        )

      assert second.parent != first.parent
      assert second.binding.resource_registry != first.binding.resource_registry
      {resumed, resume_events, resume_owner} = exercise(second)
      assert resume_owner != initial_owner
      assert resumed.record.id == retained.id
      assert resumed.record.revision == 4
      assert resumed.record.snapshot["revision"] == 4
      assert resumed.record.snapshot["machine"]["phase"] == "completed"
      assert resumed.record.snapshot["machine"]["segment"] == 1
      assert resumed.record.snapshot["source"] === retained.snapshot["source"]
      assert resumed.record.snapshot["journal"] === retained.snapshot["journal"]
      if version == 2, do: assert(resumed.record.snapshot["consumed_effects"] == 0)

      assert resumed.envelope == %{
               "ok" => true,
               "status" => "ok",
               "output" => [@projection],
               "requiresApproval" => nil
             }

      assert String.valid?(hd(resumed.envelope["output"]))
      assert {:ok, final} = Continuations.load(session_id, retained.id)
      assert final === resumed.record
      assert final.snapshot === Jason.decode!(Jason.encode!(final.snapshot))
      assert [] == returns(resume_events, Continuations, :create, 4)

      assert [{claim_index, {:ok, claimed}}, {_, {:ok, completed}}] =
               returns(resume_events, Continuations, :commit, 5)

      assert claimed.revision == 3
      assert claimed.snapshot["revision"] == 3
      assert completed === final
      assert_stored_units(claimed.snapshot)
      assert_stored_units(final.snapshot)
      claim_requests = if mode == "same_stage", do: @claim_same, else: @claim_next
      assert requests(Enum.take(resume_events, claim_index)) == claim_requests

      suffix =
        if mode == "same_stage",
          do: [
            ["compile_schema", "ask_constructor"],
            ["compile_schema", "request_metadata"],
            ["compile_schema", "request_response"],
            ["validate_response", "request_response"]
          ],
          else: []

      assert requests(resume_events) == claim_requests ++ suffix ++ [["render_template", nil]]

      renders =
        for {_, {:ok, %{"outcome" => "rendered"} = receipt}} <-
              returns(resume_events, PortSession, :fulfill, 4),
            do: receipt

      assert [%{"value" => %{"type" => "string", "value" => @projection}, "cacheEntries" => 1}] =
               Enum.map(renders, &Map.take(&1, ["value", "cacheEntries"]))

      fulfill_calls = calls(resume_events, PortSession, :fulfill)
      assert length(Enum.uniq(for {_, [broker, _, _, _]} <- fulfill_calls, do: broker)) == 1
      assert_retirement(second, resumed, resume_events)
      assert resumed.retirement.helper.os_pid != initial.retirement.helper.os_pid
      close_root(second)
      refute Process.alive?(resume_owner)
    end
  end

  defp assert_stored_units(snapshot) do
    heap = snapshot["machine"]["heap"]

    matches =
      for {id,
           %{
             "type" => "object",
             "keys" => keys,
             "fields_utf16le" => %{"Pdg=" => @low},
             "fields" => %{"Pdg=" => %{"type" => "string", "value" => "ordinary"}, "nested" => _}
           }} <- heap["nodes"],
          keys == [@high, "Pdg=", "nested"],
          do: %{"type" => "reference", "id" => id}

    assert matches != []

    for object <- matches do
      assert Value.object_get(object, @high, heap) == @low

      assert Value.to_utf16le(Value.key_string(hd(Value.object_keys(object, heap)))) ==
               <<55357::little-16>>

      nested = Value.object_get(object, "nested", heap)
      assert Value.object_keys(nested, heap) == [@low]
      assert Value.object_get(nested, @low, heap) == @high
      assert Value.to_utf16le(Value.object_get(nested, @low, heap)) == <<55357::little-16>>
    end
  end

  defp open_root(session_id, agent, store, action, project_root, file_scope) do
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id

    ceiling = %{
      caller: caller,
      run_id: run_id,
      grants: @names,
      tool_revision: 1,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

    assert {:ok, session} = Session.start_link(owner_pid: self(), cleanup_timeout: 5_000)
    assert {:ok, binding} = Session.bind(session, ceiling, incarnation: 1)

    assert {:ok, native} =
             CodeMode.bundles(%{session_binding: binding}, ceiling, ["exec", "wait"])

    descriptor = %{
      tool_name: @caller,
      tool_revision: 1,
      backend: CallerBackend,
      backend_context: %{
        observer: self(),
        project_root: project_root,
        file_scope: file_scope,
        action: action,
        session_id: session_id,
        caller: caller,
        session_binding: binding,
        profiles_context: %{session: %{id: session_id}, agent: %{id: agent.id, name: agent.name}},
        schema_runtime: %{
          node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
          helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")
        }
      },
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, catalog} = Catalog.compose(native, [descriptor], ceiling, @names)

    assert {:ok, parent} =
             Headless.start_link(
               run_id: run_id,
               incarnation: 1,
               session_binding: binding,
               registry: catalog.registry,
               tools: catalog.tools,
               authority: catalog.authority,
               store: Store,
               context: store,
               subscriber: self(),
               work: 8,
               run_timeout: 90_000,
               effect_timeout: 70_000,
               commit_timeout: 5_000,
               cleanup_timeout: 5_000
             )

    on_exit(fn ->
      if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000)
      if Process.alive?(session), do: GenServer.stop(session, :normal, 5_000)
    end)

    %{
      parent: parent,
      session: session,
      binding: binding,
      store: store,
      run_id: run_id,
      caller: caller
    }
  end

  defp exercise(fixture) do
    assert {:ok, %{run_id: run_id}} = Headless.execute(fixture.parent, @source)
    assert run_id == fixture.run_id
    assert_receive {:segment_outcome, owner, operation, result}, 60_000
    assert {:ok, outcome} = result
    assert operation.caller == fixture.caller
    assert {:ok, native} = Headless.await(fixture.parent, timeout: 20_000)
    assert native.status == :completed
    assert native.value == outcome.envelope
    assert native.nested_invocations == 1
    assert {:ok, aggregate} = Store.load(fixture.store, fixture.run_id)
    assert aggregate.run.state == :completed
    {outcome, drain([]), owner}
  end

  defp assert_retirement(fixture, outcome, events) do
    retirement = outcome.retirement
    assert retirement.release == :confirmed
    assert retirement.broker == :terminated
    assert retirement.resource_handle.kind == :workflow_schema
    assert retirement.resource_handle.owner_id == fixture.binding.owner_id
    assert retirement.resource_handle.incarnation == fixture.binding.incarnation
    assert retirement.helper.cleanup_confirmed

    if os_pid = retirement.helper.os_pid do
      assert retirement.helper.exit_status == 0
      refute File.exists?("/proc/#{os_pid}")
    end

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(
               fixture.binding.resource_registry,
               retirement.resource_handle,
               fixture.binding.owner_id
             )

    assert [{register_index, [_, _, :workflow_schema, broker, options]}] =
             calls(events, ResourceRegistry, :register)

    assert options[:owner_pid] == self_from_events(events)
    refute Process.alive?(broker)
    assert [{_, {:ok, close_status}}] = returns(events, PortSession, :close, 1)
    assert close_status === retirement.helper

    for {index, [^broker, _, _, _]} <- calls(events, PortSession, :fulfill),
        do: assert(register_index < index)

    assert [{_, {:ok, :ok}}] = returns(events, ResourceRegistry, :release, 3)
  end

  defp self_from_events(events) do
    {:trace, owner, :call, _} = Enum.find(events, &match?({:trace, _, :call, _}, &1))
    owner
  end

  defp close_root(fixture) do
    parent_ref = Process.monitor(fixture.parent)
    assert :ok = GenServer.stop(fixture.parent, :normal, 5_000)
    assert_receive {:DOWN, ^parent_ref, :process, _, :normal}, 5_000
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
    session_ref = Process.monitor(fixture.session)
    assert :ok = GenServer.stop(fixture.session, :normal, 5_000)
    assert_receive {:DOWN, ^session_ref, :process, _, :normal}, 5_000
  end

  defp install_observation do
    for {module, _, _} = target <- @targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(target, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    on_exit(fn -> for target <- @targets, do: :erlang.trace_pattern(target, false, [:local]) end)
  end

  defp drain(events) do
    receive do
      {:trace, _, _, _} = event -> drain([event | events])
      {:trace, _, _, _, _} = event -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp requests(events),
    do:
      for(
        {_, [request_helper, request, _heap, _timeout]} <- calls(events, PortSession, :fulfill),
        is_pid(request_helper),
        do: [request["kind"], request["boundary"]]
      )

  defp calls(events, module, function),
    do:
      for(
        {{:trace, _, :call, {^module, ^function, args}}, index} <- Enum.with_index(events),
        do: {index, args}
      )

  defp returns(events, module, function, arity),
    do:
      for(
        {{:trace, _, :return_from, {^module, ^function, ^arity}, value}, index} <-
          Enum.with_index(events),
        do: {index, value}
      )

  defp cleanup(session_id, namespace) do
    encoded = Base.url_encode64(namespace, padding: false)

    for prefix <- [
          "coord/workflow_continuations/" <> session_id <> "/",
          "coord/runtime/runs/" <> encoded <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end
end
