defmodule Synapsis.Session.NativeWorkflowFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{Policy, Workflows}
  alias Synapsis.Agent.Tools.Workflows.Segment
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.Workflow.Continuations
  alias Synapsis.Workflow.Schema.PortSession

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::lobster"
  @node System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
  @fixture Path.expand(
             "../../../../synapsis_core/test/fixtures/workflow_segment_cases.json",
             __DIR__
           )
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
  @oracle Path.expand("../../fixtures/openclaw/488631c/lobster.json", __DIR__)
  @external_resource @oracle
  @schema @oracle |> File.read!() |> Jason.decode!() |> get_in(["metadata", "parameters"])
  @empty "{\n  \"ok\": true,\n  \"status\": \"ok\",\n  \"output\": [],\n  \"requiresApproval\": null\n}"
  @ready "{\n  \"ok\": true,\n  \"status\": \"ok\",\n  \"output\": [\n    {\n      \"tag\": \"ready\"\n    }\n  ],\n  \"requiresApproval\": null\n}"
  @checkpoint "{\n  \"ok\": true,\n  \"status\": \"needs_input\",\n  \"output\": [],\n  \"requiresApproval\": null,\n  \"requiresInput\": {\n    \"prompt\": \"Choose tag\",\n    \"responseSchema\": {\n      \"type\": \"object\",\n      \"properties\": {\n        \"tag\": {\n          \"type\": \"string\"\n        }\n      },\n      \"required\": [\n        \"tag\"\n      ],\n      \"additionalProperties\": false\n    },\n    \"resumeToken\": \"TOKEN\",\n    \"type\": \"input_request\"\n  }\n}"
  # Additional ordinary map callers retain every original case and assertion.
  @map_cases (for item <- @cases, item["name"] != "complete" do
                item
                |> Map.put("name", "map_" <> item["name"])
                |> Map.update!(
                  "pipeline",
                  &String.replace(
                    &1,
                    "| pick tag",
                    "| map --wrap answer | map --unwrap answer | map tag={{tag}} | pick tag"
                  )
                )
                |> Map.update!("resumed_program", fn names ->
                  Enum.flat_map(names, fn
                    "pick" -> ["map", "map", "map", "pick"]
                    name -> [name]
                  end)
                end)
              end)
  @cases @cases ++ @map_cases
  # Additional where callers preserve both original and map caller families.
  @where_cases (for item <- @cases, item["name"] in ["same_stage", "next_stage"] do
                  item
                  |> Map.put("name", "where_" <> item["name"])
                  |> Map.update!(
                    "pipeline",
                    &String.replace(&1, "| pick tag", "| where tag=ready | pick tag")
                  )
                  |> Map.update!("resumed_program", fn names ->
                    Enum.flat_map(names, fn
                      "pick" -> ["where", "pick"]
                      name -> [name]
                    end)
                  end)
                end)
  @cases @cases ++ @where_cases
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

  for item <- @cases do
    @item item
    test "#{item["name"]} public tool crosses actual Worker, native Session, provider, Parts and Concord",
         ctx do
      harness = harness(ctx.tmp_dir)
      tracer = start_trace()
      owner = self()

      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        index =
          Agent.get_and_update(harness.counter, fn state ->
            {length(state.provider_requests),
             %{state | provider_requests: state.provider_requests ++ [request]}}
          end)

        send(owner, {:workflow_request, index, request, self()})

        if rem(index, 2) == 0 do
          send(owner, {:workflow_runtime, index, runtime(harness.session.id)})

          receive do
            {:invoke_workflow, id, arguments} -> function_call(conn, id, arguments)
          after
            15_000 -> raise "ordinary workflow fixture command was not delivered"
          end
        else
          receive do
            :deliver_final -> answer(conn)
          after
            15_000 -> raise "ordinary workflow final answer was not delivered"
          end
        end
      end)

      SessionHarness.subscribe!(harness.session.id)
      SessionHarness.ensure_running!(harness.session.id)
      await_idle(harness.session.id)
      assert :ok = Worker.switch_model(harness.session.id, harness.provider.name, "gpt-4o")

      arguments = %{
        "action" => "run",
        "pipeline" => @item["pipeline"],
        "timeoutMs" => 45_000,
        "maxStdoutBytes" => 4096
      }

      assert :ok = Worker.send_message(harness.session.id, "Run the selected pure workflow")
      {first, request, gate} = await_invocation(0)
      assert_catalog(first, request, harness)
      root_monitor = Process.monitor(first.root)
      send(gate, {:invoke_workflow, "workflow-run", arguments})
      assert_receive {:workflow_request, 1, following, final_gate}, 20_000
      events = trace_snapshot(tracer)
      run = segment_result(events, :run)
      assert run.record.revision == 2
      assert run.record.agent_id == harness.agent_config.id
      assert run.record.session_id == harness.session.id
      assert {:ok, saved} = Continuations.load(harness.session.id, run.record.id)
      assert saved === run.record
      assert saved.snapshot["revision"] == 2
      assert saved.snapshot["journal"] == %{"kind" => "workflow", "version" => 1, "effects" => []}

      expected =
        if @item["name"] == "complete",
          do: @empty,
          else: String.replace(@checkpoint, "TOKEN", run.envelope["requiresInput"]["resumeToken"])

      assert_invocation(events, "workflow-run", arguments, 45_000)
      assert_schema(events, @item["before_requests"])
      assert_retirement(events, first, run)
      assert_cas(events, [1, 2])
      assert_native_result(first, "workflow-run", expected)
      finish_turn(harness, first, root_monitor, final_gate)
      assert_history(harness.session.id, following, [{"workflow-run", arguments, expected}])
      assert_aggregate(first, "workflow-run", expected)

      if @item["name"] != "complete" do
        checkpoint = saved.snapshot["machine"]["checkpoint"]
        assert checkpoint["mode"] == @item["mode"]
        assert checkpoint["stage_index"] == 1
        assert checkpoint["replay_items"] == []
        assert saved.snapshot["machine"]["heap"]["nodes"] != %{}
        stop_completed_worker(harness, first)
        SessionHarness.ensure_running!(harness.session.id)
        await_idle(harness.session.id)
        [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        assert new_worker != first.worker
        assert :ok = Worker.switch_model(harness.session.id, harness.provider.name, "gpt-4o")
        trace_snapshot(tracer)

        resume_args = %{
          "action" => "resume",
          "token" => run.envelope["requiresInput"]["resumeToken"],
          "responseJson" => @item["response_json"],
          "timeoutMs" => 45_000,
          "maxStdoutBytes" => 4096
        }

        assert :ok = Worker.send_message(harness.session.id, "Resume with the supplied answer")
        {second, request, gate} = await_invocation(2)
        assert_catalog(second, request, harness)
        assert second.root != first.root
        assert second.adapter != first.adapter
        assert second.binding.session != first.binding.session
        assert second.run_id != first.run_id
        root_monitor = Process.monitor(second.root)
        send(gate, {:invoke_workflow, "workflow-resume", resume_args})
        assert_receive {:workflow_request, 3, following, final_gate}, 20_000
        events = trace_snapshot(tracer)
        resumed = segment_result(events, :resume)
        assert resumed.record.id == run.record.id
        assert resumed.record.revision == 4
        assert resumed.record.snapshot["machine"]["segment"] == 1

        assert Enum.map(resumed.record.snapshot["machine"]["program"], & &1["name"]) ==
                 @item["resumed_program"]

        assert resumed.record.snapshot["source"] === saved.snapshot["source"]
        assert {:ok, completed} = Continuations.load(harness.session.id, saved.id)
        assert completed === resumed.record
        assert_cas(events, [3, 4])
        claim = events |> successful_records() |> Enum.find(&(&1.revision == 3))
        assert claim.snapshot["machine"]["phase"] == "construct"
        assert claim.snapshot["machine"]["frames"] == []
        assert claim.snapshot["machine"]["stack"] == [%{"op" => "construct"}]
        assert claim.snapshot["machine"]["heap"]["nodes"] != %{}
        assert_schema(events, @item["claim_requests"] ++ @item["after_requests"])
        assert_invocation(events, "workflow-resume", resume_args, 45_000)
        assert_retirement(events, second, resumed)
        assert resumed.retirement.helper.os_pid != run.retirement.helper.os_pid
        assert_native_result(second, "workflow-resume", @ready)
        finish_turn(harness, second, root_monitor, final_gate)

        assert_history(harness.session.id, following, [
          {"workflow-run", arguments, expected},
          {"workflow-resume", resume_args, @ready}
        ])

        assert_aggregate(second, "workflow-resume", @ready)
        stop_completed_worker(harness, second)
      else
        stop_completed_worker(harness, first)
      end
    end
  end

  defp harness(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(h)

      case Synapsis.Providers.get_by_name(h.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok, _} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@name]})

    assert {:ok, _} =
             Synapsis.Providers.create(%{
               name: h.provider.name,
               type: "openai_responses",
               base_url: h.provider.base_url,
               api_key_encrypted: "test-key"
             })

    # Ordinary all-allow fixture prerequisite; no permission behavior is under test.
    permission = Store.get_value(h.session.id, "permission")

    assert :ok =
             Store.put_value(h.session.id, "permission", %{
               permission
               | tool_contract_version: 1,
                 allow_read: :allow,
                 allow_write: :allow,
                 allow_execute: :allow,
                 allow_destructive: :allow
             })

    h
  end

  defp await_invocation(index) do
    assert_receive {:workflow_request, ^index, request, gate}, 10_000
    assert_receive {:workflow_runtime, ^index, runtime}, 5_000
    {runtime, request, gate}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    state = :sys.get_state(data.runtime_pid, 1_000)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: state.root,
      binding: state.binding,
      session: state.session,
      catalog: :sys.get_state(state.root, 1_000).catalog,
      run_id: state.run_id,
      incarnation: state.binding.run_incarnation,
      store: state.store
    }
  end

  defp assert_catalog(runtime, request, h) do
    assert request["model"] == "gpt-4o"
    assert Enum.map(request["tools"], &ToolName.decode(&1["name"])) == [@name]

    assert Enum.find(request["tools"], &(ToolName.decode(&1["name"]) == @name))["parameters"] ===
             @schema

    assert Map.keys(runtime.catalog.registry.tools) == [@name]
    descriptor = runtime.catalog.registry.tools[@name]
    assert descriptor.backend == Workflows
    assert descriptor.tool_revision == 1
    context = descriptor.backend_context
    assert context.agent_id == h.agent_config.id
    assert context.agent_name == h.agent_name
    assert context.project_root == h.tmp_dir
    assert context.profiles_context.agent.id == h.agent_config.id
    assert context.profiles_context.agent.name == h.agent_name
    assert context.profiles_context.session.id == h.session.id
    assert context.session_binding === runtime.binding
    assert context.identity.session_id == h.session.id
    assert context.identity.run_id == runtime.run_id
    assert context.identity.incarnation == runtime.incarnation
    assert context.identity.catalog_revision == runtime.catalog.revision

    assert context.schema_runtime == %{
             node_executable: @node,
             helper_path:
               Path.join(:code.priv_dir(:synapsis_core), "workflow_schema/schema-stdio.mjs")
           }
  end

  defp finish_turn(h, runtime, monitor, gate) do
    send(gate, :deliver_final)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    root = runtime.root
    assert_receive {:DOWN, ^monitor, :process, ^root, :shutdown}, 5_000
    await_idle(h.session.id)
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

  defp stop_completed_worker(h, runtime) do
    monitors =
      for pid <- [
            runtime.worker,
            runtime.adapter,
            runtime.binding.session,
            runtime.binding.resource_registry
          ],
          do: {pid, Process.monitor(pid)}

    assert :ok = Synapsis.Session.DynamicSupervisor.stop_session(h.session.id)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      refute Process.alive?(pid)
    end
  end

  defp assert_invocation(events, id, arguments, timeout) do
    [operation] =
      for {:trace, _, :call, {Workflows, :execute, [op]}} <- events, op.tool_call_id == id, do: op

    assert operation.tool_name == @name
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
  end

  defp assert_schema(events, expected) do
    calls =
      for {:trace, _, :call, {PortSession, :fulfill, [_pid, request, _heap, timeout]}} <- events do
        assert is_integer(timeout) and timeout > 0
        [request["kind"], request["boundary"]]
      end

    assert calls == expected
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
      for {{:trace, _, :call,
            {ResourceRegistry, :register, [_registry, _owner, :workflow_schema, broker, _opts]}},
           index} <- Enum.with_index(events),
          do: {index, broker}

    refute Process.alive?(broker)

    first_fulfill =
      Enum.find_index(events, &match?({:trace, _, :call, {PortSession, :fulfill, _}}, &1))

    if first_fulfill, do: assert(index < first_fulfill)

    if os_pid do
      assert exit_status == 0
      refute File.exists?("/proc/#{os_pid}")
    end
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

  defp assert_aggregate(runtime, id, expected) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    assert aggregate.run.state == :completed

    operations =
      for {_, intent} <- aggregate.run.execution_intents,
          intent.type == :tool,
          do: intent.operation

    [operation] = Enum.filter(operations, &(&1.tool_call_id == id))
    native = aggregate.run.tool_results[operation.invocation_id]
    assert {:ok, part} = ProviderMessages.tool_result_part(id, native, @name)
    assert part.content === expected
    assert part.projection === %{"version" => 1, "result" => expected_result(expected)}
    assert part.is_error == false
  end

  defp assert_history(id, wire, expected) do
    parts =
      for message <- Synapsis.Sessions.get_messages(id),
          part <- message.parts,
          match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
          do: part

    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert length(uses) == length(expected)
    assert length(results) == length(expected)
    assert {:ok, turns} = Store.list_turns(id)

    durable =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert length(durable) == 2 * length(expected)

    for {call_id, args, text} <- expected do
      use = Enum.find(uses, &(&1.tool_use_id == call_id))
      result = Enum.find(results, &(&1.tool_use_id == call_id))
      assert use.tool == @name
      assert use.input === args
      assert result.content === text
      assert result.is_error == false
      assert result.projection === %{"version" => 1, "result" => expected_result(text)}

      assert Enum.any?(
               wire["input"],
               &(&1["type"] == "function_call" and
                   &1["call_id"] == call_id and ToolName.decode(&1["name"]) == @name and
                   Jason.decode!(&1["arguments"]) === args)
             )

      assert %{"type" => "function_call_output", "call_id" => call_id, "output" => text} in wire[
               "input"
             ]

      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == call_id and
                   &1[:name] == @name and &1[:input] === args)
             )

      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and &1[:tool_use_id] == call_id and
                   &1[:projection] === result.projection and &1[:content] === text and
                   &1[:is_error] == false)
             )
    end

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
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

  defp function_call(conn, id, arguments) do
    encoded = Jason.encode!(arguments)

    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => ToolName.encode(@name),
      "arguments" => encoded
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => encoded
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Workflow complete"},
        completed([])
      ])

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
