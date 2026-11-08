defmodule Synapsis.Session.NativeLocalRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
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

  test "native command executes in the project and persists its checked result", ctx do
    select(ctx, ["exec_command"])
    install(ctx, :command)
    assert :ok = Worker.send_message(ctx.id, "Run the native local command")
    assert_receive {:local_request, request, handler}, 5_000
    assert names(request) == ["exec_command"]
    runtime = runtime(ctx.id)
    descriptor = :sys.get_state(runtime.root).catalog.registry.tools["exec_command"]
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :local
    assert descriptor.backend_context.session_binding.run_id == runtime.run_id
    send(handler, :release_local_response)
    assert_completed()

    assert File.read!(Path.join(ctx.harness.tmp_dir, "native-local-effect.txt")) == "ok"
    assert [%ToolResult{is_error: false, projection: projection, content: text}] = results(ctx.id)
    assert text =~ "native-local-output"
    assert projection["result"]["exit_code"] == 0
    assert projection["result"]["output"] == "native-local-output"
    assert length(intents(runtime)) == 1
    assert {:ok, turns} = Store.list_turns(ctx.id)
    assert Enum.any?(turns, &Enum.any?(&1.parts, fn part -> part[:projection] == projection end))
  end

  test "execute denial rejects before intent and command side effects", ctx do
    select(ctx, ["exec_command"])
    permission = Store.get_value(ctx.id, "permission")
    assert :ok = Store.put_value(ctx.id, "permission", %{permission | allow_execute: :deny})
    install(ctx, :command)
    assert :ok = Worker.send_message(ctx.id, "Try a denied native command")
    assert_receive {:local_request, _request, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_local_response)
    assert_completed()
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "native-local-effect.txt"))
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  test "native stdin resumes a command in the next completed root turn", ctx do
    select(ctx, ["exec_command", "write_stdin"])
    install(ctx, :persistent)
    assert :ok = Worker.send_message(ctx.id, "Start the persistent native command")
    assert_receive {:local_request, _request, handler}, 5_000
    first = runtime(ctx.id)
    send(handler, :release_local_response)
    assert_completed()
    assert [%ToolResult{projection: first_projection}] = results(ctx.id)
    session_id = first_projection["result"]["session_id"]
    assert is_integer(session_id)
    assert first_projection["result"]["status"] == "running"

    assert :ok = Worker.send_message(ctx.id, "Finish the persistent native command")
    assert_receive {:local_request, _request, handler}, 5_000
    second = runtime(ctx.id)
    refute first.run_id == second.run_id
    send(handler, :release_local_response)
    assert_completed()

    assert [%ToolResult{}, %ToolResult{is_error: false, projection: projection}] = results(ctx.id)
    assert projection["result"]["output"] =~ "native-stdin=continued"
    assert projection["result"]["exit_code"] == 0
    refute Map.has_key?(projection["result"], "session_id")
    assert length(intents(first)) == 1
    assert length(intents(second)) == 1
  end

  test "native clock results complete through the same Conversation", ctx do
    select(ctx, ["clock::curr_time", "clock::sleep"])
    install(ctx, :clock)
    assert :ok = Worker.send_message(ctx.id, "Read the clock and wait briefly")
    assert_receive {:local_request, request, handler}, 5_000
    assert Enum.sort(names(request)) == ["clock::curr_time", "clock::sleep"]
    runtime = runtime(ctx.id)
    send(handler, :release_local_response)
    assert_completed()
    assert [time, sleep] = results(ctx.id)
    assert time.projection["result"]["current_time"] =~ ~r/ UTC$/
    assert sleep.projection["result"]["wall_time_seconds"] >= 0
    assert length(intents(runtime)) == 2
  end

  test "cancelling a running native command confirms process cleanup", ctx do
    select(ctx, ["exec_command"])
    install(ctx, :long_running)
    assert :ok = Worker.send_message(ctx.id, "Start a cancellable command")
    assert_receive {:local_request, _, handler}, 5_000
    send(handler, :release_local_response)
    pid = await_command_pid(ctx)
    assert File.exists?("/proc/" <> pid)
    assert :ok = Worker.cancel(ctx.id)

    eventually(fn ->
      get_in(Worker.snapshot(ctx.id), [:subagents, :root, :status]) == :closed
    end)

    eventually(fn -> not File.exists?("/proc/" <> pid) end)
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "native-command-survived.txt"))
  end

  test "session owner loss clears native processes and rejects restored handles", ctx do
    select(ctx, ["exec_command", "write_stdin"])
    install(ctx, :survivor)
    assert :ok = Worker.send_message(ctx.id, "Start a command owned by this session")
    assert_receive {:local_request, _, handler}, 5_000
    first = runtime(ctx.id)
    adapter_ref = Process.monitor(first.adapter)
    send(handler, :release_local_response)
    assert_completed()
    assert [%ToolResult{projection: projection}] = results(ctx.id)
    session_id = projection["result"]["session_id"]
    assert is_integer(session_id)
    pid = await_command_pid(ctx)
    Process.exit(first.worker, :kill)
    assert_receive {:DOWN, ^adapter_ref, :process, _, _}, 10_000
    eventually(fn -> not File.exists?("/proc/" <> pid) end)

    eventually(fn ->
      case Registry.lookup(Synapsis.Session.Registry, ctx.id) do
        [{worker, _}] -> worker != first.worker
        _ -> false
      end
    end)

    assert :ok = Worker.send_message(ctx.id, "Try the prior command handle after owner loss")
    assert_receive {:local_request, _, stale_handler}, 5_000
    second = runtime(ctx.id)
    send(stale_handler, :release_local_response)
    assert_completed()
    assert [%ToolResult{}, %ToolResult{is_error: true}] = results(ctx.id)
    assert intents(second) == []
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "native-command-survived.txt"))
  end

  defp select(ctx, tools) do
    assert {:ok, _} = Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{tools: tools})
    SessionHarness.ensure_running!(ctx.id)
  end

  defp install(ctx, scenario) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      messages = request["messages"]

      Agent.update(
        ctx.harness.counter,
        &%{&1 | provider_requests: &1.provider_requests ++ [request]}
      )

      previous =
        Enum.find(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "local-one"))

      second = Enum.any?(messages, &(&1["tool_call_id"] == "local-two"))

      cond do
        scenario == :survivor and
          Enum.any?(messages, &(user_text(&1) == "Try the prior command handle after owner loss")) and
            not second ->
          send(owner, {:local_request, request, self()})

          case AbortableHTTP.await(conn, :release_local_response, 5_000, owner) do
            {:released, conn} ->
              [_, id] = Regex.run(~r/Session ID: (\d+)/, previous["content"])

              call(conn, "write_stdin", "local-two", %{
                "session_id" => String.to_integer(id),
                "chars" => "unsafe\n"
              })

            {_, conn} ->
              conn
          end

        scenario == :persistent and
          Enum.any?(messages, &(user_text(&1) == "Finish the persistent native command")) and
            not second ->
          send(owner, {:local_request, request, self()})

          case AbortableHTTP.await(conn, :release_local_response, 5_000, owner) do
            {:released, conn} ->
              [_, session_id] = Regex.run(~r/Session ID: (\d+)/, previous["content"])

              call(conn, "write_stdin", "local-two", %{
                "session_id" => String.to_integer(session_id),
                "chars" => "continued\n",
                "yield_time_ms" => 1000
              })

            {_, conn} ->
              conn
          end

        (scenario == :clock and previous) && not second ->
          call(conn, "clock::sleep", "local-two", %{"duration_ms" => 1})

        previous ->
          answer(conn)

        true ->
          send(owner, {:local_request, request, self()})

          case AbortableHTTP.await(conn, :release_local_response, 5_000, owner) do
            {:released, conn} -> initial(conn, scenario)
            {_, conn} -> conn
          end
      end
    end)
  end

  defp initial(conn, :command),
    do:
      call(conn, "exec_command", "local-one", %{
        "cmd" => "printf native-local-output; printf ok > native-local-effect.txt",
        "login" => false,
        "yield_time_ms" => 1000
      })

  defp initial(conn, :persistent),
    do:
      call(conn, "exec_command", "local-one", %{
        "cmd" => "read value; printf 'native-stdin=%s' \"$value\"",
        "login" => false,
        "yield_time_ms" => 0
      })

  defp initial(conn, :clock), do: call(conn, "clock::curr_time", "local-one", %{})

  defp initial(conn, scenario) when scenario in [:long_running, :survivor],
    do:
      call(conn, "exec_command", "local-one", %{
        "cmd" =>
          "printf '%s' \"$$\" > native-command.pid; read value; printf '%s' \"$value\" > native-command-survived.txt",
        "login" => false,
        "yield_time_ms" => if(scenario == :survivor, do: 0, else: 1000)
      })

  defp call(conn, name, id, args),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp answer(conn),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("native local complete"),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp names(request), do: Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"]))

  defp user_text(%{"role" => "user", "content" => content}) when is_binary(content),
    do: content

  defp user_text(%{"role" => "user", "content" => content}) when is_list(content),
    do: Enum.map_join(content, &(&1["text"] || ""))

  defp user_text(_), do: nil

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    %{
      root: state.root,
      store: state.store,
      run_id: state.run_id,
      adapter: data.runtime_pid,
      worker: worker
    }
  end

  defp await_command_pid(ctx) do
    path = Path.join(ctx.harness.tmp_dir, "native-command.pid")
    eventually(fn -> match?({:ok, value} when byte_size(value) > 0, File.read(path)) end)
    pid = File.read!(path)
    assert pid =~ ~r/^\d+$/
    pid
  end

  defp eventually(check, remaining \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, remaining) do
    if check.() do
      :ok
    else
      Process.sleep(25)
      eventually(check, remaining - 1)
    end
  end

  defp results(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        result = %ToolResult{} <- message.parts,
        do: result
      )

  defp intents(runtime) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end

  defp assert_completed, do: assert_receive({:run_event, %{type: "session.completed"}}, 10_000)
end
