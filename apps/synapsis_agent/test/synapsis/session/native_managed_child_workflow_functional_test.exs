defmodule Synapsis.Session.NativeManagedChildWorkflowFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{Backend, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{Policy, Workflows}
  alias Synapsis.Agent.Tools.Workflows.Segment
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.Workflow.Continuations
  alias Synapsis.Workflow.Schema.PortSession

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::lobster"
  @collaboration ~w(spawn_agent wait_agent followup_task)
  @names [@name | @collaboration]
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @child_name "/root/workflow_child"
  @initial "managed workflow initial task marker"
  @followup "managed workflow followup task marker"
  @second_final "managed workflow followup complete: ready"
  @parent_final "managed workflow parent complete"
  @fixture Path.expand(
             "../../../../synapsis_core/test/fixtures/workflow_segment_cases.json",
             __DIR__
           )
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
  @oracle Path.expand("../../fixtures/openclaw/488631c/lobster.json", __DIR__)
  @external_resource @oracle
  @schema @oracle |> File.read!() |> Jason.decode!() |> get_in(["metadata", "parameters"])
  @ready "{\n  \"ok\": true,\n  \"status\": \"ok\",\n  \"output\": [\n    {\n      \"tag\": \"ready\"\n    }\n  ],\n  \"requiresApproval\": null\n}"
  @checkpoint "{\n  \"ok\": true,\n  \"status\": \"needs_input\",\n  \"output\": [],\n  \"requiresApproval\": null,\n  \"requiresInput\": {\n    \"prompt\": \"Choose tag\",\n    \"responseSchema\": {\n      \"type\": \"object\",\n      \"properties\": {\n        \"tag\": {\n          \"type\": \"string\"\n        }\n      },\n      \"required\": [\n        \"tag\"\n      ],\n      \"additionalProperties\": false\n    },\n    \"resumeToken\": \"TOKEN\",\n    \"type\": \"input_request\"\n  }\n}"
  @targets [
    {Workflows, :execute, 1},
    {Policy, :tool_effect_timeout, 2},
    {Segment, :run, 2},
    {Segment, :resume, 4},
    {Continuations, :create, 4},
    {Continuations, :commit, 5},
    {PortSession, :fulfill, 4},
    {PortSession, :close, 1},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3}
  ]

  setup do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)
    Application.put_env(:synapsis_agent, :filesystem_node, @node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    :ok
  end

  # Public pure v1 only. Provider gates observe production state; every tool,
  # validation receipt, durable CAS and cleanup transition is production-owned.
  for item <- Enum.filter(@cases, &(&1["name"] in ["same_stage", "next_stage"])) do
    @item item
    test "#{item["name"]} managed child resumes its real public workflow through explicit followup",
         ctx do
      scenario(ctx.tmp_dir, @item)
    end
  end

  defp scenario(root, item) do
    h = harness(root)
    tracer = start_trace()
    install_provider(h)
    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    await_idle(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Delegate the selected pure workflow")

    {root_wire, root_http} = request(:root)
    runtime = runtime(h.session.id)
    root_scope = scope(runtime.root, runtime.binding)
    assert_catalog(root_wire, root_scope, h)

    spawn_call =
      {"spawn-child", "spawn_agent",
       %{"task_name" => "workflow_child", "message" => @initial, "fork_turns" => "none"}}

    respond(root_http, spawn_call)

    {child_wire, child_http} = request(:child)
    original = child(runtime.manager)
    binding = Keyword.fetch!(original.opts, :session_binding)
    initial = scope(original.pid, binding)
    assert original.incarnation == 1
    assert original.run_id == initial.run_id
    assert original.request.options["fork_turns"] == "none"
    assert_catalog(child_wire, initial, h)
    assert_distinct_scope(root_scope, initial, :distinct_session)
    assert :sys.get_state(runtime.adapter).child_sessions[original.id].binding === binding
    assert user_texts(child_wire) == [@initial]
    trace_snapshot(tracer)

    args = %{
      "action" => "run",
      "pipeline" => item["pipeline"],
      "timeoutMs" => 45_000,
      "maxStdoutBytes" => 4096
    }

    run_call = {"child-workflow-run", @name, args}
    respond(child_http, run_call)
    {child_after_run, child_http} = request(:child)
    run_events = trace_snapshot(tracer)
    run = segment_result(run_events, :run)
    assert_cas(run_events, [1, 2])
    assert_schema_receipts(run_events, item["before_requests"])
    assert_invocation(run_events, "child-workflow-run", args, 45_000, initial)
    assert_retirement(run_events, initial, run)
    assert run.record.agent_id == h.agent_config.id
    assert run.record.session_id == h.session.id
    assert {:ok, saved} = Continuations.load(h.session.id, run.record.id)
    assert saved === run.record
    assert saved.revision == 2
    assert {:ok, _} = Ecto.UUID.cast(saved.id)
    assert saved.snapshot["version"] == 1
    assert saved.snapshot["revision"] == 2
    assert saved.snapshot["journal"] == %{"kind" => "workflow", "version" => 1, "effects" => []}
    assert Enum.map(saved.snapshot["machine"]["program"], & &1["name"]) == item["program"]
    checkpoint = saved.snapshot["machine"]["checkpoint"]
    assert checkpoint["mode"] == item["mode"]
    assert checkpoint["stage_index"] == 1
    assert checkpoint["replay_items"] == []
    assert saved.snapshot["machine"]["heap"]["nodes"] != %{}

    token = run.envelope["requiresInput"]["resumeToken"]
    assert is_binary(token)
    assert "workflow-segment.v1." <> locator = token

    assert Jason.decode!(Base.url_decode64!(locator, padding: false)) ==
             %{"workflowId" => saved.id, "revision" => 2}

    expected = String.replace(@checkpoint, "TOKEN", token)
    initial_journal = journal(runtime, initial.run_id, [run_call])
    assert_workflow_history(child_after_run, initial_journal, run_call, expected)
    assert_native_result(initial, "child-workflow-run", expected)
    first_final = "managed workflow initial checkpoint: " <> token
    respond(child_http, {:answer, first_final})
    completed_child(runtime.manager, 1, first_final)
    assert_child_detached(binding)

    {_root_after_spawn, root_http} = request(:root)
    wait_first = {"wait-first", "wait_agent", %{"timeout_ms" => 10_000}}
    respond(root_http, wait_first)
    {root_after_wait, root_http} = request(:root)
    assert inspect(root_after_wait["messages"]) =~ first_final

    [feedback_token] =
      Regex.scan(
        ~r/workflow-segment\.v1\.[A-Za-z0-9_-]+/,
        Jason.encode!(root_after_wait["messages"])
      )
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    assert feedback_token == token
    followup = @followup <> " token=" <> feedback_token <> " response=" <> item["response_json"]

    follow_call =
      {"follow-child", "followup_task", %{"target" => @child_name, "message" => followup}}

    respond(root_http, follow_call)

    {followup_wire, followup_http} = request(:followup)
    replacement = child(runtime.manager)
    fresh_binding = Keyword.fetch!(replacement.opts, :session_binding)
    fresh = scope(replacement.pid, fresh_binding)
    assert replacement.id == original.id
    assert replacement.name == @child_name
    assert replacement.incarnation == 2
    assert replacement.run_id == fresh.run_id
    assert_catalog(followup_wire, fresh, h)
    assert_distinct_scope(initial, fresh, :retained_session)
    assert_distinct_scope(root_scope, fresh, :distinct_session)
    assert :sys.get_state(runtime.adapter).child_sessions[original.id].binding === fresh_binding
    refute Process.alive?(original.pid)
    assert user_texts(followup_wire) == [@initial, followup]
    assert inspect(followup_wire["messages"]) =~ first_final
    assert_workflow_history(followup_wire, initial_journal, run_call, expected)
    assert {:ok, ^saved} = Continuations.load(h.session.id, saved.id)
    between_segments = trace_snapshot(tracer)
    refute Enum.any?(between_segments, &match?({:trace, _, :call, {Workflows, :execute, _}}, &1))
    refute Enum.any?(between_segments, &match?({:trace, _, :call, {Segment, :run, _}}, &1))

    refute Enum.any?(
             between_segments,
             &match?({:trace, _, :call, {Continuations, :create, _}}, &1)
           )

    assert_schema_receipts(between_segments, [])

    [fresh_token] =
      Regex.scan(~r/workflow-segment\.v1\.[A-Za-z0-9_-]+/, List.last(user_texts(followup_wire)))
      |> Enum.map(&hd/1)

    assert fresh_token == feedback_token

    resume_args = %{
      "action" => "resume",
      "token" => fresh_token,
      "responseJson" => item["response_json"],
      "timeoutMs" => 45_000,
      "maxStdoutBytes" => 4096
    }

    resume_call = {"child-workflow-resume", @name, resume_args}
    respond(followup_http, resume_call)
    {followup_after_resume, followup_http} = request(:followup)
    resume_events = trace_snapshot(tracer)
    resumed = segment_result(resume_events, :resume)
    refute Enum.any?(resume_events, &match?({:trace, _, :call, {Segment, :run, _}}, &1))
    refute Enum.any?(resume_events, &match?({:trace, _, :call, {Continuations, :create, _}}, &1))
    assert_cas(resume_events, [3, 4])
    assert_resume_order(resume_events, item)
    assert_invocation(resume_events, "child-workflow-resume", resume_args, 45_000, fresh)
    assert_retirement(resume_events, fresh, resumed)
    assert resumed.retirement.helper.os_pid != run.retirement.helper.os_pid
    assert resumed.record.id == saved.id
    assert resumed.record.agent_id == saved.agent_id
    assert resumed.record.session_id == saved.session_id
    assert resumed.record.inserted_at == saved.inserted_at
    assert resumed.record.revision == 4
    assert {:ok, completed} = Continuations.load(h.session.id, saved.id)
    assert completed === resumed.record
    assert completed.snapshot["revision"] == 4
    assert completed.snapshot["source"] === saved.snapshot["source"]
    assert completed.snapshot["journal"] === saved.snapshot["journal"]
    assert completed.snapshot["machine"]["phase"] == "completed"
    assert completed.snapshot["machine"]["segment"] == 1

    assert Enum.map(completed.snapshot["machine"]["program"], & &1["name"]) ==
             item["resumed_program"]

    claim = Enum.find(successful_records(resume_events), &(&1.revision == 3))
    assert claim.snapshot["machine"]["phase"] == "construct"
    assert claim.snapshot["machine"]["frames"] == []
    assert claim.snapshot["machine"]["stack"] == [%{"op" => "construct"}]

    for record <- [claim, completed], {id, value} <- saved.snapshot["machine"]["heap"]["nodes"] do
      assert record.snapshot["machine"]["heap"]["nodes"][id] === value
    end

    followup_journal = journal(runtime, fresh.run_id, [resume_call])
    assert_workflow_history(followup_after_resume, initial_journal, run_call, expected)
    assert_workflow_history(followup_after_resume, followup_journal, resume_call, @ready)
    assert_native_result(fresh, "child-workflow-run", expected)
    assert_native_result(fresh, "child-workflow-resume", @ready)
    respond(followup_http, {:answer, @second_final})
    completed_child(runtime.manager, 2, @second_final)
    assert_child_detached(fresh_binding)

    {_root_after_followup, root_http} = request(:root)
    wait_second = {"wait-second", "wait_agent", %{"timeout_ms" => 10_000}}
    respond(root_http, wait_second)
    {root_after_second_wait, root_http} = request(:root)
    assert inspect(root_after_second_wait["messages"]) =~ first_final
    assert inspect(root_after_second_wait["messages"]) =~ @second_final
    calls = [spawn_call, wait_first, follow_call, wait_second]
    assert_wire_calls(root_after_second_wait, calls)
    respond(root_http, {:answer, @parent_final})
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    await(fn -> Worker.get_status(h.session.id) == :waiting end)

    assert [%{name: @child_name, incarnation: 2, status: :completed}] =
             Worker.snapshot(h.session.id).subagents.agents

    root_journal = journal(runtime, root_scope.run_id, calls)
    initial_journal = journal(runtime, initial.run_id, [run_call])
    followup_journal = journal(runtime, fresh.run_id, [resume_call])

    for {aggregate, final} <- [
          {root_journal, @parent_final},
          {initial_journal, first_final},
          {followup_journal, @second_final}
        ] do
      assert aggregate.run.state == :completed
      assert inspect(aggregate.run.context.conversation.messages) =~ final
    end

    assert_native_history(followup_journal, [run_call, resume_call])
    assert inspect(followup_journal.run.context.conversation.messages) =~ first_final
    assert inspect(root_journal.run.context.conversation.messages) =~ first_final
    assert inspect(root_journal.run.context.conversation.messages) =~ @second_final
    assert_workflow_native(initial_journal, run_call, expected)
    assert_workflow_native(followup_journal, resume_call, @ready)
    assert {:ok, intents} = Synapsis.Runtime.Store.list_facts(h.session.id, :admission_intent)
    assert {:ok, receipts} = Synapsis.Runtime.Store.list_facts(h.session.id, :admission_receipt)
    assert length(intents) == 2
    assert Enum.count(receipts, &(&1.status == :created and &1.process_started)) == 2
    assert_parent_parts(h.session.id, root_journal, calls, first_final)
  end

  defp harness(root) do
    assert {:ok, counter} = Agent.start_link(fn -> %{provider_requests: []} end)
    provider = DeterministicProvider.start!(install?: false)
    name = "managed-workflow-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, agent_config} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: provider.name,
               model: "gpt-4o",
               tools: @names,
               tool_contract_version: 1,
               permission_mode: "yolo",
               config: %{"workspace_path" => root}
             })

    assert {:ok, session} =
             Synapsis.Sessions.create(name, %{
               agent: name,
               provider: provider.name,
               model: "gpt-4o",
               config: %{"subagents" => true, "memory_context" => false}
             })

    harness = %{
      session: session,
      agent_config: agent_config,
      agent_name: name,
      provider: provider,
      counter: counter,
      tool_name: nil,
      tmp_dir: root
    }

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    permission = Store.get_value(session.id, "permission")

    # Ordinary all-allow configuration is a prerequisite, not permission coverage.
    assert :ok =
             Store.put_value(session.id, "permission", %{
               permission
               | tool_contract_version: 1,
                 allow_read: :allow,
                 allow_write: :allow,
                 allow_execute: :allow,
                 allow_destructive: :allow
             })

    harness
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | provider_requests: &1.provider_requests ++ [wire]})
      users = user_texts(wire)

      scope =
        cond do
          Enum.any?(users, &String.starts_with?(&1, @followup)) -> :followup
          @initial in users -> :child
          true -> :root
        end

      send(owner, {:managed_workflow_request, scope, wire, self()})
      {:released, conn} = AbortableHTTP.await(conn, :release_workflow_response, 30_000, owner)

      receive do
        {:workflow_response, {:answer, text}} ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk(text),
            DeterministicProvider.finish_chunk("stop")
          ])

        {:workflow_response, {id, name, arguments}} ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ])
      after
        5_000 -> raise "ordinary workflow provider response was not supplied"
      end
    end)
  end

  defp request(scope) do
    assert_receive {:managed_workflow_request, ^scope, wire, http}, 15_000
    {wire, http}
  end

  defp respond(http, response) do
    send(http, {:workflow_response, response})
    send(http, :release_workflow_response)
  end

  defp user_texts(wire) do
    for %{"role" => "user", "content" => content} <- wire["messages"], do: wire_text(content)
  end

  defp wire_text(content) when is_binary(content), do: content
  defp wire_text(parts) when is_list(parts), do: Enum.map_join(parts, &(&1["text"] || ""))

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    Map.merge(Map.take(state, [:root, :manager, :binding, :session, :store]), %{
      adapter: data.runtime_pid
    })
  end

  defp child(manager), do: :sys.get_state(manager).agents[@child_name]

  defp scope(pid, binding) do
    state = :sys.get_state(pid)

    %{
      root: pid,
      catalog: state.catalog,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      binding: binding
    }
  end

  defp assert_catalog(wire, scope, h) do
    assert wire["model"] == "gpt-4o"

    assert Enum.sort(Enum.map(wire["tools"], &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort(@names)

    assert Enum.sort(Map.keys(scope.catalog.registry.tools)) == Enum.sort(@names)
    assert scope.catalog.revision == 1
    public = Enum.find(wire["tools"], &(ToolName.decode(&1["function"]["name"]) == @name))
    assert public["function"]["parameters"] === @schema
    descriptor = scope.catalog.registry.tools[@name]
    assert descriptor.backend == Workflows
    assert descriptor.tool_revision == 1
    context = descriptor.backend_context
    assert context.agent_id == h.agent_config.id
    assert context.agent_name == h.agent_name
    assert context.project_root == h.tmp_dir
    assert context.profiles_context.agent.id == h.agent_config.id
    assert context.profiles_context.agent.name == h.agent_name
    assert context.profiles_context.session.id == h.session.id
    assert context.session_binding === scope.binding

    assert context.identity == %{
             caller: "synapsis:" <> h.session.id,
             session_id: h.session.id,
             run_id: scope.run_id,
             incarnation: scope.incarnation,
             catalog_revision: scope.catalog.revision
           }

    assert context.schema_runtime == %{
             node_executable: @node,
             helper_path:
               Path.join(:code.priv_dir(:synapsis_core), "workflow_schema/schema-stdio.mjs")
           }

    for name <- @collaboration do
      descriptor = scope.catalog.registry.tools[name]
      assert descriptor.backend == Backend
      assert descriptor.tool_revision == 1
      assert descriptor.backend_context.session_binding === scope.binding
    end
  end

  defp assert_distinct_scope(previous, current, session_mode) do
    assert previous.root != current.root
    assert previous.run_id != current.run_id
    assert previous.binding != current.binding
    assert previous.binding.token != current.binding.token

    case session_mode do
      :distinct_session ->
        assert previous.binding.session != current.binding.session
        assert previous.binding.resource_registry != current.binding.resource_registry

      :retained_session ->
        assert previous.binding.session == current.binding.session
        assert previous.binding.resource_registry == current.binding.resource_registry
        assert previous.binding.owner_id == current.binding.owner_id
        assert previous.binding.incarnation == current.binding.incarnation
        assert current.binding.run_incarnation == previous.binding.run_incarnation + 1
        assert Process.alive?(current.binding.session)
        assert Process.alive?(current.binding.resource_registry)
    end

    assert previous.catalog.registry.tools[@name].backend_context !=
             current.catalog.registry.tools[@name].backend_context
  end

  # Successful completion detaches the Conversation and retains its Session owner.
  # Explicit followup binds a fresh run to that same idle Session and registry.
  defp assert_child_detached(binding) do
    await(fn ->
      Session.status(binding.session).phase == :idle
    end)

    status = Session.status(binding.session)
    assert status.owner_id == binding.owner_id
    assert status.incarnation == binding.incarnation
    assert :sys.get_state(binding.session).active == nil
    assert Process.alive?(binding.session)
    assert Process.alive?(binding.resource_registry)
  end

  defp journal(runtime, run_id, calls) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, run_id)

    for {_, intent} <- aggregate.run.execution_intents,
        intent.type == :tool,
        do: assert(intent.status == :consumed)

    operations = operations(aggregate)

    assert Enum.sort(Enum.map(operations, & &1.tool_call_id)) ==
             Enum.sort(Enum.map(calls, &elem(&1, 0)))

    for {id, name, arguments} <- calls do
      operation = Enum.find(operations, &(&1.tool_call_id == id))
      assert operation.run_id == run_id
      assert operation.tool_name == name
      assert operation.tool_revision == 1
      assert operation.arguments == arguments
      assert aggregate.run.tool_results[operation.invocation_id].is_error == false
    end

    assert_native_history(aggregate, calls)
    aggregate
  end

  defp operations(aggregate) do
    for {_, intent} <- aggregate.run.execution_intents, intent.type == :tool, do: intent.operation
  end

  defp assert_native_history(aggregate, calls) do
    messages = aggregate.run.context.conversation.messages

    native_calls =
      Enum.flat_map(messages, fn message ->
        blocks = if is_list(message[:content]), do: message.content, else: []
        Enum.filter(blocks, &(&1[:type] == :tool_call)) ++ Map.get(message, :tool_calls, [])
      end)

    for {id, name, arguments} <- calls do
      assert Enum.count(
               native_calls,
               &(&1.id == id and &1.name == name and &1.arguments == arguments)
             ) == 1

      assert Enum.count(messages, &(&1[:role] == :tool and &1[:tool_call_id] == id)) == 1
    end
  end

  defp assert_wire_calls(wire, calls) do
    wire_calls =
      for message <- wire["messages"], call <- Map.get(message, "tool_calls", []), do: call

    for {id, name, arguments} <- calls do
      assert Enum.count(wire_calls, fn call ->
               call["id"] == id and ToolName.decode(call["function"]["name"]) == name and
                 Jason.decode!(call["function"]["arguments"]) == arguments
             end) == 1
    end
  end

  defp assert_workflow_history(wire, aggregate, {id, _name, _args} = call, text) do
    assert_wire_calls(wire, [call])
    assert_workflow_native(aggregate, call, text)

    assert Enum.count(
             wire["messages"],
             &(&1["role"] == "tool" and
                 &1["tool_call_id"] == id and &1["content"] === text)
           ) == 1
  end

  defp assert_workflow_native(aggregate, {id, name, _args}, text) do
    op = Enum.find(operations(aggregate), &(&1.tool_call_id == id))
    native = aggregate.run.tool_results[op.invocation_id]
    assert {:ok, part} = ProviderMessages.tool_result_part(id, native, name)
    assert part.content === text
    assert part.is_error == false
    assert part.projection === %{"version" => 1, "result" => expected_result(text)}
    assert {:ok, dump} = Synapsis.Part.dump(part)
    assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()

    [message] =
      for %{role: :tool, tool_call_id: ^id} = m <- aggregate.run.context.conversation.messages,
          do: m

    assert message.result === native
  end

  defp assert_invocation(events, id, arguments, timeout, scope) do
    [operation] =
      for {:trace, _, :call, {Workflows, :execute, [op]}} <- events, op.tool_call_id == id, do: op

    assert operation.tool_name == @name
    assert operation.tool_revision == 1
    assert operation.run_id == scope.run_id
    assert operation.backend_context.session_binding === scope.binding

    assert operation.backend_context.identity ===
             scope.catalog.registry.tools[@name].backend_context.identity

    assert operation.arguments === arguments
    [deadline] = for {:workflow_deadline, ^id, {:ok, deadline}} <- events, do: deadline
    assert deadline.selected_timeout_ms == timeout
    assert deadline.remaining_ms > 0 and deadline.remaining_ms <= timeout

    assert Enum.any?(
             events,
             &match?(
               {:trace, _, :return_from, {Policy, :tool_effect_timeout, 2}, {:ok, ^timeout}},
               &1
             )
           )
  end

  defp segment_result(events, function) do
    [result] =
      for {:trace, _, :return_from, {Segment, ^function, _}, {:ok, result}} <- events,
          do: result

    result
  end

  defp successful_records(events) do
    for {:trace, _, :return_from, {Continuations, function, _}, {:ok, record}} <- events,
        function in [:create, :commit],
        do: record
  end

  defp assert_cas(events, expected) do
    records = successful_records(events)
    assert Enum.map(records, & &1.revision) == expected
    assert Enum.map(records, & &1.snapshot["revision"]) == expected
    assert length(Enum.uniq(Enum.map(records, & &1.id))) == 1

    {pending, acknowledged} =
      Enum.reduce(events, {%{}, []}, fn
        {:trace, pid, :call, {Continuations, :create, [_session, _agent, _snapshot, _opts]}},
        {pending, revisions} ->
          refute Map.has_key?(pending, pid)
          {Map.put(pending, pid, {:create, 1}), revisions}

        {:trace, pid, :call,
         {Continuations, :commit, [_session, _id, revision, _snapshot, _opts]}},
        {pending, revisions} ->
          refute Map.has_key?(pending, pid)
          {Map.put(pending, pid, {:commit, revision + 1}), revisions}

        {:trace, pid, :return_from, {Continuations, function, _}, result}, {pending, revisions}
        when function in [:create, :commit] ->
          {^function, revision} = Map.fetch!(pending, pid)
          assert {:ok, %{revision: ^revision}} = result
          {Map.delete(pending, pid), revisions ++ [revision]}

        _, state ->
          state
      end)

    assert pending == %{}
    assert acknowledged == expected
  end

  defp assert_schema(events, expected) do
    calls =
      for {:trace, _, :call, {PortSession, :fulfill, [_pid, request, _heap, timeout]}} <- events do
        assert is_integer(timeout) and timeout > 0
        [request["kind"], request["boundary"]]
      end

    assert calls == expected
  end

  defp assert_schema_receipts(events, expected) do
    assert_schema(events, expected)

    {pending, actual} =
      Enum.reduce(events, {%{}, []}, fn
        {:trace, pid, :call, {PortSession, :fulfill, [_broker, request, _heap, _timeout]}},
        {pending, actual} ->
          refute Map.has_key?(pending, pid)
          {Map.put(pending, pid, request), actual}

        {:trace, pid, :return_from, {PortSession, :fulfill, 4}, result}, {pending, actual} ->
          request = Map.fetch!(pending, pid)
          pending = Map.delete(pending, pid)
          expected_outcome = if request["kind"] == "compile_schema", do: "compiled", else: "valid"
          assert {:ok, %{"id" => id, "result" => "ok", "outcome" => ^expected_outcome}} = result
          assert id == request["id"]
          {pending, actual ++ [[request["kind"], request["boundary"]]]}

        _, state ->
          state
      end)

    assert pending == %{}
    assert actual == expected
  end

  defp assert_resume_order(events, item) do
    assert_schema_receipts(events, item["claim_requests"] ++ item["after_requests"])

    {before_claim, [claim_ack | after_claim]} =
      Enum.split_while(events, fn
        {:trace, _, :return_from, {Continuations, :commit, 5}, {:ok, %{revision: 3}}} -> false
        _ -> true
      end)

    assert {:trace, _, :return_from, {Continuations, :commit, 5}, {:ok, %{revision: 3}}} =
             claim_ack

    assert_schema_receipts(before_claim, item["claim_requests"])
    assert_schema_receipts(after_claim, item["after_requests"])
  end

  defp assert_retirement(events, runtime, result) do
    assert %{
             resource_handle: handle,
             release: :confirmed,
             helper: %{cleanup_confirmed: true, os_pid: os_pid, exit_status: exit_status},
             broker: :terminated
           } = result.retirement

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(
               runtime.binding.resource_registry,
               handle,
               runtime.binding.owner_id
             )

    [{index, broker}] =
      for {{:trace, caller, :call,
            {ResourceRegistry, :register, [registry, owner, :workflow_schema, broker, opts]}},
           index} <- Enum.with_index(events),
          do: begin_registration(index, broker, registry, owner, opts, runtime.binding, caller)

    refute Process.alive?(broker)

    first_fulfill =
      Enum.find_index(events, &match?({:trace, _, :call, {PortSession, :fulfill, _}}, &1))

    if first_fulfill, do: assert(index < first_fulfill)

    assert is_integer(os_pid) and os_pid > 0
    assert exit_status == 0
    refute File.exists?("/proc/#{os_pid}")
  end

  defp begin_registration(index, broker, registry, owner, opts, binding, caller) do
    assert registry == binding.resource_registry
    assert owner == binding.owner_id
    assert opts[:incarnation] == binding.incarnation
    assert opts[:owner_pid] == caller
    {index, broker}
  end

  defp expected_result(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "details" => Jason.decode!(text),
      "is_error" => false
    }

  defp assert_native_result(runtime, id, expected) do
    messages = Backplane.AgentRuntime.Conversation.status(runtime.root).messages
    [message] = for %{role: :tool, tool_call_id: ^id} = message <- messages, do: message
    assert {:ok, part} = ProviderMessages.tool_result_part(id, message.result, @name)
    assert part.content === expected
    assert part.is_error == false
    assert part.projection === %{"version" => 1, "result" => expected_result(expected)}
  end

  defp assert_parent_parts(id, root_journal, calls, first_final) do
    parts = for message <- Synapsis.Sessions.get_messages(id), part <- message.parts, do: part
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))

    for {id, name, _arguments} <- calls do
      operation = Enum.find(operations(root_journal), &(&1.tool_call_id == id))

      assert {:ok, expected} =
               ProviderMessages.tool_result_part(
                 id,
                 root_journal.run.tool_results[operation.invocation_id],
                 name
               )

      assert Enum.find(results, &(&1.tool_use_id == id)) == expected
    end

    text = for %Text{content: content} <- parts, do: content

    for marker <- [first_final, @second_final, @parent_final],
        do: assert(Enum.any?(text, &String.contains?(&1, marker)))

    assert {:ok, turns} = Store.list_turns(id)
    durable = for turn <- turns, part <- turn.parts, do: part
    assert Enum.count(durable, &(&1[:type] == "tool_use")) == length(calls)
    assert Enum.count(durable, &(&1[:type] == "tool_result")) == length(calls)

    for use <- uses do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and &1[:name] == use.tool and
                   &1[:input] == use.input)
             )
    end

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                   &1[:content] == result.content and &1[:projection] == result.projection and
                   &1[:is_error] == false)
             )
    end

    for marker <- [first_final, @second_final, @parent_final],
        do: assert(inspect(durable) =~ marker)

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp completed_child(manager, incarnation, final) do
    await(fn ->
      current = child(manager)

      current.incarnation == incarnation and current.status == :completed and
        current.final == [%{type: :text, text: final}] and
        (current.result_delivery || %{})[:status] == :accepted
    end)
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + 10_000)

  defp await(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "ordinary managed workflow progress was not observed"

      Process.sleep(10)
      await(predicate, deadline)
    end
  end

  # Worker registration precedes its asynchronous pending-input boot/read lane.
  # Observe normal readiness before changing models or retiring the Worker.
  defp await_idle(id), do: await_idle(id, System.monotonic_time(:millisecond) + 5_000)

  defp await_idle(id, deadline) do
    status = Worker.public_status(id)

    case status do
      {:ok, %{runtime: %{phase: "idle", active: false}}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_idle(id, deadline)
          end
        else
          flunk("Worker did not finish its ordinary readiness lane: #{inspect(status)}")
        end
    end
  end

  defp start_trace do
    tracer = spawn(fn -> trace_loop([]) end)

    for {module, _, _} = target <- @targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(target, [{:_, [], [{:return_trace}]}], [:local]) == 1
    end

    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      :erlang.trace(:new, false, [:call])
      :erlang.trace(:all, false, [:call])
      for target <- @targets, do: :erlang.trace_pattern(target, false, [:local])
      if Process.alive?(tracer), do: send(tracer, :stop)
    end)

    tracer
  end

  defp trace_loop(events) do
    receive do
      {:trace, _pid, :call, {Workflows, :execute, [operation]}} = event ->
        deadline =
          {:workflow_deadline, operation.tool_call_id,
           operation.backend_context.effect_deadline.()}

        trace_loop([deadline, event | events])

      {:snapshot, owner, ref} ->
        send(owner, {ref, Enum.reverse(events)})
        trace_loop([])

      :stop ->
        :ok

      event ->
        trace_loop([event | events])
    end
  end

  defp trace_snapshot(tracer) do
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 5_000
    ref = make_ref()
    send(tracer, {:snapshot, self(), ref})
    assert_receive {^ref, events}, 5_000
    events
  end
end
