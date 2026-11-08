defmodule Synapsis.Session.NativeBrowserTimingFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog, ToolRegistry}
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{Browser, Policy}
  alias Synapsis.Browser.{PortSession, Timing}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(timing-start timing-open timing-automatic timing-batch timing-read)

  # Separate public-runtime observers; Browser remains direct_model_only.
  defmodule DeadlineProvider do
    def stream(request, _context) do
      calls =
        if Enum.any?(request.messages, &(&1[:role] == :tool)),
          do: [],
          else: [
            %{
              type: :tool_call_completed,
              tool_call: %{id: "observe-outer", name: "timing::outer", arguments: %{}}
            }
          ]

      calls ++ [%{type: :response_completed, message: %{role: :assistant, content: "observed"}}]
    end
  end

  defmodule DeadlineHooks do
    def tool_effect_timeout(invocation, %{catalog_snapshot: %{registry: registry}}) do
      {:ok, descriptor} = ToolRegistry.lookup(registry, invocation.tool_name)
      {:ok, descriptor.backend_context.selected_timeout_ms}
    end
  end

  defmodule DeadlineOuter do
    def execute(%{backend_context: context}) do
      {:ok, before} = context.effect_deadline.()
      {:ok, result} = context.nested_dispatch.(%{tool_name: "timing::child", arguments: %{}})
      {:ok, after_child} = context.effect_deadline.()
      send(context.owner, {:outer_allowance, context.scenario, before, after_child})
      {:ok, %{content: result.content}}
    end
  end

  defmodule DeadlineChild do
    def execute(%{backend_context: context}) do
      {:ok, first} = context.effect_deadline.()
      Process.sleep(25)
      {:ok, second} = context.effect_deadline.()
      send(context.owner, {:child_allowance, context.scenario, first, second})
      {:ok, %{content: "same finite allowance"}}
    end
  end

  test "public native getters retain selection while clipping to root and enclosing allowances" do
    for {scenario, root, outer, child} <- [
          {:root, 5_000, 10_000, 20_000},
          {:enclosing, 20_000, 5_000, 10_000}
        ] do
      run_id = "timing-observer-#{scenario}-#{Ecto.UUID.generate()}"
      {:ok, table} = EphemeralStore.new(1)

      descriptors =
        for {name, backend, selected} <- [
              {"timing::outer", DeadlineOuter, outer},
              {"timing::child", DeadlineChild, child}
            ] do
          %{
            tool_name: name,
            tool_revision: 1,
            description: "Ordinary native deadline observer",
            schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
            backend: backend,
            backend_context: %{owner: self(), scenario: scenario, selected_timeout_ms: selected},
            safety: %{read_only: true, retry_safe: false, parallel_safe: false}
          }
        end

      authority = %{
        caller: "timing-observer",
        run_id: run_id,
        grants: Enum.map(descriptors, & &1.tool_name),
        tool_revision: 1
      }

      assert {:ok, catalog} =
               ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

      options = [
        run_id: run_id,
        store: EphemeralStore,
        context: table,
        provider: DeadlineProvider,
        hooks: DeadlineHooks,
        subscriber: self(),
        registry: catalog.registry,
        tools: catalog.tools,
        authority: catalog.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: root,
        effect_timeout: 1_000,
        commit_timeout: 1_000,
        cleanup_timeout: 1_000
      ]

      conversation = start_supervised!({Conversation, options})
      assert {:ok, _} = Conversation.prompt(conversation, "Observe ordinary nested timing")
      assert_receive {:child_allowance, ^scenario, first, second}, 2_000
      assert_receive {:outer_allowance, ^scenario, before, after_child}, 2_000
      assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000

      assert before.selected_timeout_ms == outer
      assert before.remaining_ms <= min(root, outer)
      assert before.remaining_ms > 0
      assert first.selected_timeout_ms == child
      assert first.remaining_ms <= before.remaining_ms
      assert first.remaining_ms < child
      assert first.deadline_ms <= before.deadline_ms
      assert second.selected_timeout_ms == child
      assert second.deadline_ms == first.deadline_ms
      assert second.remaining_ms < first.remaining_ms
      assert second.remaining_ms > 0
      assert after_child.selected_timeout_ms == outer
      assert after_child.deadline_ms == before.deadline_ms
      assert after_child.remaining_ms < before.remaining_ms
      assert Enum.all?([before, first, second, after_child], &(&1.paused == false))

      assert %{phase: :terminal, run: %{state: :completed}} = Conversation.status(conversation)
      assert {:ok, %{run: %{state: :completed}}} = EphemeralStore.load(table, run_id)
      monitor = Process.monitor(conversation)
      assert :ok = GenServer.stop(conversation)
      assert_receive {:DOWN, ^monitor, :process, ^conversation, :normal}, 1_000
      :ets.delete(table)
    end
  end

  test "automatic standalone and batch budgets outlive the profile default with raw durable replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    tracer = trace_browser(self())
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Inspect local Browser timing")
    requests = for index <- 0..5, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    assert receipt(final, "timing-read")["value"] == "timed"
    assert receipt(final, "timing-automatic")["ok"] == true
    assert receipt(final, "timing-batch")["results"] == [%{"ok" => true}, %{"ok" => true}]

    for {id, input} <- [
          {"timing-automatic", call_input(2, final, harness)},
          {"timing-batch", call_input(3, final, harness)}
        ] do
      assert {:ok, plan} = Timing.plan(harness.browser_config, input)
      assert_receive {:browser_deadline, ^id, {:ok, deadline}}, 5_000
      assert deadline.selected_timeout_ms == plan.native_timeout_ms
      assert deadline.paused == false
      assert is_integer(deadline.deadline_ms)
      assert deadline.remaining_ms > plan.outer_timeout_ms
      assert deadline.remaining_ms <= deadline.selected_timeout_ms
      assert_receive {:port_deadline, ^id, "act", forwarded, timeout}, 5_000
      assert forwarded == input["args"]
      assert timeout <= plan.outer_timeout_ms
      assert timeout > 1500
    end

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(uses, & &1.input) == for(index <- 0..4, do: call_input(index, final, harness))
    assert Enum.all?(results, &(&1.is_error == false))

    for {request, count} <- Enum.with_index(requests),
        do: assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    {_resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)
    stop_trace(tracer)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall completed Browser timing")
    replay = receive_request(6)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 7
    {_resource, replay_broker} = browser_resource(harness.session.id)
    assert :sys.get_state(replay_broker).port == nil
    assert Agent.get(harness.counter, & &1.page_loads) == 1
  end

  test "non-Browser tools retain the shared native default" do
    assert Policy.tool_effect_timeout(%{tool_name: "synapsis::web_search"}, %{}) == :default
  end

  defp browser_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.put(&1, :page_loads, 0))
    repository = Path.expand("../../../../..", __DIR__)

    browser = %{
      "default_profile" => "managed",
      "node_executable" => System.find_executable("node"),
      "helper_path" => Path.join(repository, "packages/tool-host/src/browser/stdio.mjs"),
      "profiles" => %{
        "managed" => %{
          "driver" => "managed-host",
          "target" => "host",
          "executable" => "/run/current-system/sw/bin/chromium",
          "data_dir" => Path.join(root, "browser-data"),
          "timeout_ms" => 1500
        }
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: Map.put(harness.agent_config.config, "browser", browser)
             })

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(
        200,
        "<!doctype html><html><body><h1>Browser timing</h1><script>window.timing='timed'</script></body></html>"
      )
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    Map.put(harness, :browser_config, browser)
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:browser_wait_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _, _), do: %{"action" => "start", "timeout_ms" => 15_000}

  defp call_input(1, _, harness),
    do: %{
      "action" => "open",
      "timeout_ms" => 15_000,
      "args" => %{"targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/page")}
    }

  defp call_input(2, request, _),
    do: %{
      "action" => "act",
      "args" => %{
        "targetId" => target_id(request),
        "request" => %{"kind" => "wait", "timeMs" => 2000}
      }
    }

  defp call_input(3, request, _),
    do: %{
      "action" => "act",
      "args" => %{
        "targetId" => target_id(request),
        "request" => %{
          "kind" => "batch",
          "actions" => List.duplicate(%{"kind" => "wait", "timeMs" => 900}, 2)
        }
      }
    }

  defp call_input(4, request, _),
    do: %{
      "action" => "act",
      "args" => %{
        "targetId" => target_id(request),
        "request" => %{"kind" => "evaluate", "fn" => "() => window.timing"}
      }
    }

  defp trace_browser(owner) do
    Code.ensure_loaded!(Browser)
    Code.ensure_loaded!(PortSession)
    tracer = spawn(fn -> trace_loop(owner, %{}) end)
    assert :erlang.trace_pattern({Browser, :execute, 1}, true, [:local]) == 1
    assert :erlang.trace_pattern({PortSession, :call, 4}, true, [:local]) == 1
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])
    on_exit(fn -> stop_trace(tracer) end)
    tracer
  end

  defp stop_trace(tracer) do
    :erlang.trace(:new, false, [:call])
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({Browser, :execute, 1}, false, [:local])
    :erlang.trace_pattern({PortSession, :call, 4}, false, [:local])
    if Process.alive?(tracer), do: send(tracer, :stop)
  end

  defp trace_loop(owner, calls) do
    receive do
      {:trace, pid, :call, {Browser, :execute, [operation]}} ->
        id = operation.tool_call_id

        if operation.arguments["action"] == "act",
          do: send(owner, {:browser_deadline, id, operation.backend_context.effect_deadline.()})

        trace_loop(owner, Map.put(calls, pid, id))

      {:trace, pid, :call, {PortSession, :call, [_broker, action, args, timeout]}} ->
        send(owner, {:port_deadline, calls[pid], action, args, timeout})
        trace_loop(owner, calls)

      :stop ->
        :ok
    end
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_wait_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "timing-open")["targetId"]

  defp receipt(request, id) do
    result =
      Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

    text = result["content"] |> Enum.find(&(&1["type"] == "text")) |> Map.fetch!("text")
    Jason.decode!(text)
  end

  defp assert_wire_history(request, uses, results) do
    blocks = blocks(request)

    assert Enum.filter(blocks, &(&1["type"] == "tool_use")) ==
             Enum.map(uses, fn part ->
               %{
                 "type" => "tool_use",
                 "id" => part.tool_use_id,
                 "name" => ToolName.encode(part.tool),
                 "input" => part.input
               }
             end)

    assert Enum.filter(blocks, &(&1["type"] == "tool_result")) ==
             Enum.map(results, fn part ->
               %{
                 "type" => "tool_result",
                 "tool_use_id" => part.tool_use_id,
                 "is_error" => false,
                 "content" => [
                   %{"type" => "text", "text" => part.projection["result"]["content"]}
                 ]
               }
             end)
  end

  defp browser_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_part_round_trips(parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns) do
      assert {:ok, ^turn} = Store.get_turn(id, index)
    end

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(raw, &(&1[:type] == "tool_use")) ==
             Enum.map(uses, fn part ->
               %{
                 type: "tool_use",
                 id: part.tool_use_id,
                 name: part.tool,
                 input: part.input,
                 status: to_string(part.status)
               }
             end)

    assert Enum.filter(raw, &(&1[:type] == "tool_result")) ==
             Enum.map(results, fn part ->
               %{
                 type: "tool_result",
                 tool_use_id: part.tool_use_id,
                 content: part.content,
                 is_error: part.is_error,
                 projection: part.projection
               }
             end)
  end

  defp browser_resource(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    adapter = :sys.get_state(data.runtime_pid, 1_000)
    assert [resource] = Map.values(adapter.browser_resources)
    assert %{"managed" => %{pid: broker}} = resource.profiles
    assert Process.alive?(broker)
    {resource, broker}
  end

  defp owned_processes(broker) do
    port = :sys.get_state(broker, 1_000).port
    assert is_port(port)
    assert {:os_pid, helper} = Port.info(port, :os_pid)

    children =
      "/proc/#{helper}/task/#{helper}/children"
      |> File.read!()
      |> String.split()
      |> Enum.map(&String.to_integer/1)

    assert children != []
    [helper | children]
  end

  defp assert_owned_exited(pids) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    await_owned_exit(pids, deadline)
  end

  defp await_owned_exit(pids, deadline) do
    alive = Enum.filter(pids, &File.exists?("/proc/#{&1}"))

    if alive != [] do
      assert System.monotonic_time(:millisecond) < deadline,
             "owned Browser processes did not exit: #{inspect(alive)}"

      Process.sleep(10)
      await_owned_exit(alive, deadline)
    end
  end

  defp provider_response(conn, call) do
    {content, delta, stop} =
      case call do
        {id, input} ->
          {%{"type" => "tool_use", "id" => id, "name" => ToolName.encode(@name), "input" => %{}},
           %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}

        nil ->
          {%{"type" => "text", "text" => ""},
           %{"type" => "text_delta", "text" => "Browser timing inspected"}, "end_turn"}
      end

    events = [
      %{"type" => "content_block_start", "index" => 0, "content_block" => content},
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => stop}},
      %{"type" => "message_stop"}
    ]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(
      200,
      Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
    )
  end
end
