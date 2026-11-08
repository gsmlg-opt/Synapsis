defmodule Synapsis.Session.NativeHistoryWindowOracle do
  @moduledoc false
  import ExUnit.Assertions

  # These are independent test adapters around the pinned original factory,
  # kernel and preparation. They do not import product history/DTO algorithms.
  def expected(id, input, selected, total, operation \\ "recent", extra \\ %{}, pending \\ nil) do
    args =
      input
      |> Map.drop(["session_id", "message_id", "pending_before", "include_tools"])
      |> Map.put("sessionKey", "agent:main:history291")
      |> copy(input, "message_id", "messageId")
      |> copy(input, "pending_before", "pendingBefore")
      |> copy(input, "include_tools", "includeTools")

    result =
      Map.merge(
        %{
          "messages" => selected,
          "totalMessages" => total,
          "displaySource" => "supplied-history291",
          "readWindow" => %{"source" => "supplied-history291", "latestResetRawSeq" => nil}
        },
        extra
      )

    request = %{
      "id" => "host-positive",
      "args" => args,
      "max" => Map.get(input, "limit", 200),
      "reads" => [%{"operation" => operation, "result" => result}],
      "pendingInputs" => pending || %{"items" => [], "total" => 0},
      "hostId" => id
    }

    script = ~S"""
    import {pathToFileURL} from 'node:url';
    const oraclePath = process.argv[1];
    process.argv.splice(1,1);
    const {computeSessionHistoryWindow} = await import(pathToFileURL(oraclePath).href);
    let data = '';
    for await (const chunk of process.stdin) { data += chunk; if (data.includes('\n')) break; }
    const input = JSON.parse(data.trim());
    const observation = await computeSessionHistoryWindow(input);
    const original = JSON.parse(observation.result.content[0].text);
    const page = Object.fromEntries(Object.entries(original).map(([key,value]) =>
      [key === 'sessionKey' ? 'session_id' : key,key === 'sessionKey' ? input.hostId : value]));
    if (page.pendingInputs) {
      const before = Buffer.byteLength(JSON.stringify(page.pendingInputs),'utf8');
      const kinds = new Map((input.pendingInputs.items ?? []).map(item => [item.id,item.kind]));
      page.pendingInputs.items = page.pendingInputs.items.map(item => ({...item,...(kinds.has(item.id)?{kind:kinds.get(item.id)}:{})}));
      page.bytes += Buffer.byteLength(JSON.stringify(page.pendingInputs),'utf8') - before;
    }
    await new Promise((resolve, reject) => {
      process.stdout.write(JSON.stringify({page,text:JSON.stringify(page,null,2)}), error => error ? reject(error) : resolve());
    });
    process.exit(0);
    """

    oracle =
      Path.expand("../../../../../scripts/openclaw/capture-session-history-window.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node_executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["--experimental-vm-modules", "--input-type=module", "-e", script, oracle]
      ])

    assert Port.command(port, Jason.encode!(request) <> "\n")
    collect(port, "")
  end

  def node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")

  def message(role, text),
    do: %Synapsis.Message{
      id: Ecto.UUID.generate(),
      role: role,
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      parts: [%Synapsis.Part.Text{content: text}]
    }

  def source(message, ordinal, content \\ nil),
    do: %{
      "role" => message.role,
      "timestamp" => DateTime.to_iso8601(message.inserted_at),
      "__openclaw" => %{"id" => message.id, "seq" => ordinal},
      "content" => content || Enum.map(message.parts, &%{"type" => "text", "text" => &1.content})
    }

  def persist(messages) do
    id = Ecto.UUID.generate()

    assert :ok =
             Synapsis.Session.Store.put_meta(id, %{id: id, agent: "archive", title: "History 雪"})

    for chunk <- Enum.chunk_every(Enum.with_index(messages), 500) do
      puts =
        Enum.map(chunk, fn {message, index} ->
          {Synapsis.Session.Store.turn_key(id, index * 7), Synapsis.Message.encode(message)}
        end)

      assert {:ok, _} = Concord.Turso.put_many(puts, timeout: 5_000)
    end

    ExUnit.Callbacks.on_exit(fn -> Synapsis.Session.Store.delete_session(id) end)
    id
  end

  def tool_archive do
    arguments = %{"fraction" => 1.0e-7, "path" => "reports/雪😀.md", "items" => [1, true, nil]}

    public = %{
      "content" => [%{"type" => "text", "text" => "Published report 雪"}],
      "details" => %{"count" => 2, "fraction" => 1.0e-7},
      "structured" => %{"path" => arguments["path"]},
      "is_error" => false
    }

    use = %Synapsis.Part.ToolUse{
      tool: "read_file",
      tool_use_id: "archive-read",
      input: arguments,
      status: :completed
    }

    result = %Synapsis.Part.ToolResult{
      tool_use_id: "archive-read",
      content: "Published report 雪",
      projection: %{"version" => 1, "result" => public}
    }

    messages = [
      message("user", "Read the ordinary report."),
      %{message("assistant", "") | parts: [%Synapsis.Part.Text{content: "Reading."}, use]},
      %{message("tool", "") | parts: [result]},
      %{message("user", "") | parts: [result]},
      message("assistant", "Report complete 😀")
    ]

    call = %{
      "type" => "toolCall",
      "id" => "archive-read",
      "name" => "read_file",
      "arguments" => arguments
    }

    reply =
      public
      |> Map.delete("is_error")
      |> Map.merge(%{"toolCallId" => "archive-read", "isError" => false})

    [first, second, third, fourth, fifth] = messages

    rows = [
      source(first, 1),
      source(second, 2, [%{"type" => "text", "text" => "Reading."}, call]),
      source(third, 3, public["content"]) |> Map.merge(reply) |> Map.put("role", "toolResult"),
      source(fourth, 4, [Map.put(reply, "type", "toolResult")]),
      source(fifth, 5)
    ]

    %{id: persist(messages), messages: messages, rows: rows, arguments: arguments, public: public}
  end

  def pending(input),
    do: %{
      "id" => input.id,
      "state" => input.status,
      "kind" => input.kind,
      "acceptedAt" => input.inserted_at,
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => input.content}]
      }
    }

  defp copy(args, input, key, target) do
    if Map.has_key?(input, key), do: Map.put(args, target, input[key]), else: args
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, output <> chunk)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(output)

      {^port, {:exit_status, status}} ->
        flunk("pinned original history oracle exit #{status}: #{output}")
    after
      30_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("pinned original history oracle did not finish")
    end
  end
end

defmodule Synapsis.Session.NativeSessionHistoryWindowFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionHistory
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, NativeHistoryWindowOracle, PendingInputStore, Worker}
  alias Synapsis.Session.Store
  alias Synapsis.Message

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::sessions_history"
  @call_id "standalone-history291"

  test "admitted revision two history is acknowledged, dispatched, returned verbatim and retained after normal reopen",
       %{tmp_dir: root} do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)

    Application.put_env(
      :synapsis_agent,
      :filesystem_node,
      NativeHistoryWindowOracle.node_executable()
    )

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name]})
    archive = NativeHistoryWindowOracle.tool_archive()

    assert {:ok, first} =
             PendingInputStore.append_prompt(archive.id, "Queued next question 雪", [])

    assert {:ok, steer} = PendingInputStore.append_steer(archive.id, "Keep ordinary detail 😀")
    input = %{"session_id" => archive.id, "limit" => 5, "offset" => 0, "include_tools" => true}

    pending = %{
      "items" => Enum.map([steer, first], &NativeHistoryWindowOracle.pending/1),
      "total" => 2
    }

    expected =
      NativeHistoryWindowOracle.expected(
        archive.id,
        input,
        archive.rows,
        5,
        "recent",
        %{},
        pending
      )

    assert {:ok, original} = Store.list_turns(archive.id)
    install_provider(harness, input)
    observer = start_observer()
    on_exit(fn -> stop_observer(observer) end)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Read the standalone durable history")
    initial = receive_request(0)
    assert_catalog(initial)
    assert_receive {:history291_selected, selected}, 5_000
    assert selected.tool_revision == 2
    assert selected.backend == SessionHistory
    assert selected.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    next = receive_request(1)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {worker, adapter} = runtime(harness.session.id)
    {use, result} = assert_parts(harness.session.id, input, expected)
    assert_wire(next, input, result)
    assert_runtime(adapter, result)
    observed = observed(observer)
    [execution] = Enum.filter(observed, &(&1.kind == :execute))
    operation = execution.operation
    assert operation.tool_name == @name
    assert operation.tool_revision == 2
    assert operation.tool_call_id == @call_id
    assert operation.arguments == input

    context =
      Map.take(
        operation.backend_context,
        ~w(session_id agent_id run_id incarnation catalog_revision)a
      )

    assert {:ok, classification} =
             SessionHistory.classify(
               context,
               Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
             )

    assert classification.action == "session.history.read"
    assert classification.resource == "session_history:" <> Jason.encode!(input)
    assert_receive {:history291_request_at, 1, next_at}, 5_000
    assert_ack_order(observed, execution, result, next_at)
    assert Store.list_turns(archive.id) == {:ok, original}
    assert PendingInputStore.list(archive.id) == [first, steer]

    stop_normally(harness.session.id, worker, adapter.session)
    SessionHarness.ensure_running!(harness.session.id)
    [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute fresh == worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the saved history result")
    reopened = receive_request(2)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_catalog(reopened)
    assert_wire(reopened, input, result)
    assert assert_parts(harness.session.id, input, expected) == {use, result}
    {^fresh, replayed} = runtime(harness.session.id)
    refute replayed.session == adapter.session
    assert_runtime(replayed, result)
    refute Enum.any?(observed(observer), &(&1.kind == :execute))
    assert Store.list_turns(archive.id) == {:ok, original}
    assert PendingInputStore.list(archive.id) == [first, steer]
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
    stop_normally(harness.session.id, fresh, replayed.session)
  end

  defp install_provider(harness, input) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:history291_request_at, index, System.monotonic_time()})
      send(owner, {:history291_request, index, request})

      chunks =
        if index == 0 do
          {_, adapter} = runtime(harness.session.id)
          selected = :sys.get_state(adapter.root, 1_000).catalog.registry.tools[@name]
          send(owner, {:history291_selected, selected})

          [
            DeterministicProvider.tool_call_chunk(ToolName.encode(@name), @call_id, input),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        else
          [
            DeterministicProvider.text_chunk("History retained."),
            DeterministicProvider.finish_chunk("stop")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp assert_catalog(request) do
    assert [descriptor] = request["tools"]
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    schema = descriptor["function"]["parameters"]
    assert schema["required"] == []
    assert schema["additionalProperties"] == false
    properties = schema["properties"]

    assert Map.take(properties["limit"], ~w(type minimum maximum default)) == %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => 1000,
             "default" => 200
           }

    assert properties["offset"]["type"] == "integer"
    assert properties["offset"]["minimum"] == 0
    assert properties["pending_before"]["type"] == "integer"
    assert properties["pending_before"]["minimum"] == 1
    assert properties["message_id"]["type"] == "string"
    assert properties["include_tools"] == %{"type" => "boolean", "default" => false}

    assert Enum.sort(Map.keys(properties)) ==
             ~w(include_tools limit message_id offset pending_before session_id)
  end

  defp receive_request(index) do
    assert_receive {:history291_request, ^index, request}, 20_000
    request
  end

  defp assert_wire(request, input, result) do
    actual =
      Enum.filter(request["messages"], &(Map.has_key?(&1, "tool_calls") or &1["role"] == "tool"))

    assert actual == [
             %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => @call_id,
                   "type" => "function",
                   "function" => %{
                     "name" => ToolName.encode(@name),
                     "arguments" => Jason.encode!(input)
                   }
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => @call_id, "content" => result.content}
           ]
  end

  defp assert_parts(id, input, expected) do
    messages = Message.list_by_session(id)
    parts = for message <- messages, part <- message.parts, do: part
    assert [use] = Enum.filter(parts, &match?(%ToolUse{}, &1))
    assert [result] = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert {use.tool, use.tool_use_id, use.input} == {@name, @call_id, input}
    assert result.tool_use_id == @call_id
    assert result.is_error == false
    assert result.content == expected["text"]
    assert Jason.decode!(result.content) == expected["page"]

    assert result.projection == %{
             "version" => 1,
             "result" => %{
               "content" => expected["text"],
               "structured" => expected["page"],
               "is_error" => false
             }
           }

    assert Enum.filter(parts, &(match?(%ToolUse{}, &1) or match?(%ToolResult{}, &1))) == [
             use,
             result
           ]

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert Store.list_turns(id) == {:ok, Enum.map(messages, &Message.encode/1)}

    for {message, index} <- Enum.with_index(messages),
        do: assert(Store.get_turn(id, index) == {:ok, Message.encode(message)})

    assert {:ok, replayed} = Synapsis.Agent.Runtime.ProviderMessages.from_host(messages)
    assert [reply] = Enum.filter(replayed, &(Map.get(&1, :tool_call_id) == @call_id))
    assert json(reply.result) == result.projection["result"]
    {use, result}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, state} = :sys.get_state(worker, 1_000)
    {worker, :sys.get_state(state.runtime_pid, 1_000)}
  end

  defp assert_runtime(adapter, result) do
    assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(adapter.store, adapter.run_id)
    messages = get_in(aggregate, [:run, :context, :conversation, :messages])
    assert [reply] = Enum.filter(messages, &(&1[:role] == :tool))
    assert reply.tool_call_id == @call_id
    assert json(reply.result) == result.projection["result"]
  end

  defp stop_normally(id, worker, native) do
    worker_monitor = Process.monitor(worker)
    native_monitor = Process.monitor(native)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^native_monitor, :process, ^native, reason}, 5_000
    assert reason in [:normal, :shutdown]
  end

  defp start_observer do
    for module <- [SessionHistory, Synapsis.Agent.Runtime.Store], do: Code.ensure_loaded!(module)
    observer = spawn(fn -> collect([], %{}) end)
    :erlang.trace_pattern({SessionHistory, :execute, 1}, [{:_, [], [{:return_trace}]}], [:local])

    :erlang.trace_pattern(
      {Synapsis.Agent.Runtime.Store, :acknowledge_commit, 3},
      [{:_, [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace(:all, true, [:call, :monotonic_timestamp, {:tracer, observer}])
    observer
  end

  defp stop_observer(observer) do
    :erlang.trace(:all, false, [:call, :monotonic_timestamp])
    :erlang.trace_pattern({SessionHistory, :execute, 1}, false, [:local])
    :erlang.trace_pattern({Synapsis.Agent.Runtime.Store, :acknowledge_commit, 3}, false, [:local])
    monitor = Process.monitor(observer)
    send(observer, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
  end

  defp observed(observer) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    send(observer, {:snapshot, self()})
    assert_receive {:history291_observed, ^observer, events}, 5_000
    Enum.sort_by(events, & &1.at)
  end

  defp collect(events, pending) do
    receive do
      {:trace_ts, pid, :call,
       {Synapsis.Agent.Runtime.Store, :acknowledge_commit, [_context, stage, _meta]}, at} ->
        collect(events, Map.put(pending, pid, {stage, at}))

      {:trace_ts, pid, :return_from, {Synapsis.Agent.Runtime.Store, :acknowledge_commit, 3},
       reply, at} ->
        {{stage, started}, pending} = Map.pop!(pending, pid)

        collect(
          [
            %{kind: :ack, stage: stage, result: reply, pid: pid, started: started, at: at}
            | events
          ],
          pending
        )

      {:trace_ts, pid, :call, {SessionHistory, :execute, [operation]}, at} ->
        collect([%{kind: :execute, operation: operation, pid: pid, at: at} | events], pending)

      {:trace_ts, pid, :return_from, {SessionHistory, :execute, 1}, reply, at} ->
        collect([%{kind: :result, result: reply, pid: pid, at: at} | events], pending)

      {:snapshot, owner} ->
        send(owner, {:history291_observed, self(), Enum.reverse(events)})
        collect([], pending)

      :stop ->
        :ok
    end
  end

  defp assert_ack_order(events, execution, result, next_at) do
    invocation = execution.operation.invocation_id
    intent_key = "tool:" <> invocation

    before =
      Enum.filter(events, fn event ->
        event.kind == :ack and
          get_in(event.stage, [:run, :execution_intents, intent_key, :operation, :invocation_id]) ==
            invocation and
          get_in(event.stage, [:run, :execution_intents, intent_key, :status]) == :started
      end)

    assert before != []
    ack = Enum.find(before, &(&1.at < execution.at))
    assert ack
    assert ack.result == {:ok, %{revision: ack.stage.revision}}
    assert ack.stage.run.active_tools[invocation].invocation_id == invocation

    after_result =
      Enum.find(events, fn event ->
        event.kind == :ack and event.at > execution.at and
          get_in(event.stage, [:run, :execution_intents, intent_key, :status]) == :consumed and
          is_map(get_in(event.stage, [:run, :tool_results, invocation]))
      end)

    assert after_result
    assert [returned] = Enum.filter(events, &(&1.kind == :result))
    assert {:ok, native} = returned.result
    assert native.content == result.content
    assert returned.at < after_result.at
    assert after_result.at < next_at
    refute Map.has_key?(after_result.stage.run.active_tools, invocation)
    assert after_result.result == {:ok, %{revision: after_result.stage.revision}}
    assert json(after_result.stage.run.tool_results[invocation]) == result.projection["result"]
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
