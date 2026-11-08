defmodule Synapsis.Session.NativeToolsRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Synapsis.Agent.Runtime.SessionTools
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.WorkspaceMemory
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @get "synapsis::workspace_memory_get"
  @secret "native-memory-marker-6d97e2"

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "MEMORY.md"), "# Native memory\n#{@secret}\n")

    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    SessionHarness.subscribe!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "explicit workspace memory tool executes natively and persists structured result", ctx do
    select_tools(ctx.harness, [@get])
    install_provider(ctx.harness)
    assert :ok = Worker.send_message(ctx.id, "Read line two of MEMORY.md with the selected tool")
    assert_receive {:native_request, request, handler}, 5_000
    assert wire_names(request) == [@get]

    runtime = runtime(ctx.id)
    catalog = :sys.get_state(runtime.root).catalog
    assert Map.keys(catalog.registry.tools) == [@get]
    assert catalog.registry.tools[@get].backend == WorkspaceMemory

    refute Enum.any?(catalog.registry.tools, fn {_, descriptor} ->
             descriptor.backend == SessionTools
           end)

    send(handler, :release_native_response)
    assert_completed()

    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    native_tool = Enum.find(aggregate.run.context.conversation.messages, &(&1.role == :tool))
    assert native_tool.result[:is_error] != true, inspect(native_tool.result)

    assert [%ToolResult{is_error: false, projection: projection} = result] = tool_results(ctx.id)
    assert result.content =~ @secret
    assert projection["version"] == 1
    assert_receive {"tool_result", %{tool_use_id: "native-memory-call", projection: ^projection}}

    assert %{
             "path" => "MEMORY.md",
             "from" => 2,
             "to" => 2,
             "content" => @secret <> "\n"
           } = projection["result"]["structured"]

    assert {:ok, turns} = Store.list_turns(ctx.id)

    assert [%{projection: ^projection}] =
             for(turn <- turns, part <- turn.parts, part.type == "tool_result", do: part)

    assert [_] = tool_intents(runtime)
  end

  test "empty tool selection with subagents enabled still runs an empty real Conversation", ctx do
    SessionHarness.ensure_running!(ctx.id)
    assert {:ok, _} = Worker.set_subagents(ctx.id, true)
    select_tools(ctx.harness, [])
    install_provider(ctx.harness, tool_call?: false)
    assert :ok = Worker.send_message(ctx.id, "Reply without tools")
    assert_receive {:native_request, request, handler}, 5_000
    assert wire_names(request) == []

    runtime = runtime(ctx.id)
    assert Conversation.status(runtime.root).phase == :running
    assert :sys.get_state(runtime.root).catalog.registry.tools == %{}
    send(handler, :release_native_response)
    assert_completed()
    assert tool_results(ctx.id) == []
    assert tool_intents(runtime) == []
  end

  test "read denial prevents native execution intents and memory disclosure", ctx do
    select_tools(ctx.harness, [@get])
    set_read_permission(ctx.id, :deny)
    install_provider(ctx.harness)
    assert :ok = Worker.send_message(ctx.id, "Try the selected memory read")
    assert_receive {:native_request, request, handler}, 5_000
    assert wire_names(request) == [@get]
    runtime = runtime(ctx.id)
    send(handler, :release_native_response)
    assert_completed()
    assert_denied(ctx.harness, runtime)
  end

  test "permission change while provider waits is checked before native tool intent", ctx do
    select_tools(ctx.harness, [@get])
    set_read_permission(ctx.id, :allow)
    install_provider(ctx.harness)
    assert :ok = Worker.send_message(ctx.id, "Read memory after the provider returns")
    assert_receive {:native_request, request, handler}, 5_000
    assert wire_names(request) == [@get]
    runtime = runtime(ctx.id)
    set_read_permission(ctx.id, :deny)
    send(handler, :release_native_response)
    assert_completed()
    assert_denied(ctx.harness, runtime)
  end

  for decision <- [true, false] do
    @decision decision
    test "trusted UI/API operator approval #{@decision} settles the exact native request", ctx do
      select_tools(ctx.harness, [@get])
      permission = Store.get_value(ctx.id, "permission")

      assert :ok =
               Store.put_value(ctx.id, "permission", %{
                 permission
                 | mode: :interactive,
                   allow_read: :ask
               })

      install_provider(ctx.harness)
      assert :ok = Worker.send_message(ctx.id, "Ask the operator before reading memory")
      assert_receive {:native_request, _request, handler}, 5_000
      runtime = runtime(ctx.id)
      send(handler, :release_native_response)

      assert_receive {"runtime_permissions", [%{interaction_id: id, request: request}]}, 5_000
      assert request.operation.tool_name == @get
      assert request.operation.arguments == %{"path" => "MEMORY.md", "from" => 2, "lines" => 1}
      assert request.scope.requester_id == "synapsis:operator"
      assert request.scope.session_id == ctx.id
      assert tool_intents(runtime) == []
      assert tool_results(ctx.id) == []
      assert :ok = Worker.resolve_runtime(ctx.id, id, @decision)
      assert_completed()
      assert [%ToolResult{is_error: error, content: text}] = tool_results(ctx.id)
      assert error == not @decision
      assert String.contains?(text, @secret) == @decision
      assert length(tool_intents(runtime)) == if(@decision, do: 1, else: 0)
      assert {:error, :not_found} = Worker.resolve_runtime(ctx.id, id, true)
    end
  end

  test "operator approval rechecks permission changes before the native effect", ctx do
    select_tools(ctx.harness, [@get])
    permission = Store.get_value(ctx.id, "permission")

    assert :ok =
             Store.put_value(ctx.id, "permission", %{
               permission
               | mode: :interactive,
                 allow_read: :ask
             })

    install_provider(ctx.harness)
    assert :ok = Worker.send_message(ctx.id, "Recheck permission after approval")
    assert_receive {:native_request, _request, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_native_response)
    assert_receive {"runtime_permissions", [%{interaction_id: id}]}, 5_000
    set_read_permission(ctx.id, :deny)
    assert :ok = Worker.resolve_runtime(ctx.id, id, true)
    assert_completed()
    assert_denied(ctx.harness, runtime)
  end

  test "unknown requested capability fails visibly before HTTP without taking an intersection",
       ctx do
    unknown = "synapsis::unimplemented_capability"
    select_tools(ctx.harness, [@get, unknown])
    install_provider(ctx.harness)
    assert :ok = Worker.send_message(ctx.id, "Use the requested capabilities")
    assert_receive {"error", %{message: message}}, 5_000
    assert message =~ unknown
    assert Worker.snapshot(ctx.id).status == :error
    refute_receive {:native_request, _, _}, 100
    assert Agent.get(ctx.harness.counter, & &1.provider_requests) == []
  end

  defp select_tools(harness, tools) do
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: tools})
    SessionHarness.ensure_running!(harness.session.id)
  end

  defp set_read_permission(id, decision) do
    raw = Store.get_value(id, "permission")
    assert is_map(raw)
    assert :ok = Store.put_value(id, "permission", Map.put(raw, :allow_read, decision))
  end

  defp install_provider(harness, opts \\ []) do
    owner = self()
    tool_call? = Keyword.get(opts, :tool_call?, true)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Agent.update(harness.counter, fn state ->
        %{state | provider_requests: state.provider_requests ++ [request]}
      end)

      send(owner, {:native_request, request, self()})
      tool_result? = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      if tool_result? do
        answer(conn)
      else
        case AbortableHTTP.await(conn, :release_native_response, 5_000, owner) do
          {:disconnected, conn} ->
            conn

          {:released, conn} ->
            if tool_call? do
              DeterministicProvider.send_sse(conn, [
                DeterministicProvider.tool_call_chunk(
                  ToolName.encode(@get),
                  "native-memory-call",
                  %{"path" => "MEMORY.md", "from" => 2, "lines" => 1}
                ),
                DeterministicProvider.finish_chunk("tool_calls")
              ])
            else
              answer(conn)
            end

          {:timeout, conn} ->
            answer(conn)
        end
      end
    end)
  end

  defp answer(conn) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.text_chunk("native tool turn complete"),
      DeterministicProvider.finish_chunk("stop")
    ])
  end

  defp wire_names(request) do
    Enum.map(request["tools"] || [], &ToolName.decode(&1["function"]["name"]))
  end

  defp runtime(id) do
    worker = GenServer.whereis({:via, Registry, {Synapsis.Session.Registry, id}})
    {_state, data} = :sys.get_state(worker)

    assert is_pid(data.runtime_pid),
           "selected tools must run through the production SessionAdapter"

    state = :sys.get_state(data.runtime_pid)
    assert is_pid(state.root), "production SessionAdapter must own the root Conversation"
    %{root: state.root, store: state.store, run_id: state.run_id}
  end

  defp assert_completed do
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
  end

  defp tool_results(id) do
    for message <- Synapsis.Sessions.get_messages(id),
        %ToolResult{} = result <- message.parts,
        do: result
  end

  defp tool_intents(runtime) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end

  defp assert_denied(harness, runtime) do
    assert tool_intents(runtime) == []
    assert [%ToolResult{is_error: true} = result] = tool_results(harness.session.id)
    refute result.content =~ @secret
    refute inspect(result.projection) =~ @secret
    refute inspect(Synapsis.Sessions.get_messages(harness.session.id)) =~ @secret
    refute inspect(Agent.get(harness.counter, & &1.provider_requests)) =~ @secret
  end
end
