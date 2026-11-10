defmodule Synapsis.Session.NativeRetainedProcessFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @process "synapsis::process"

  test "existing native pipe receives real stdin EOF and emits its complete input before natural exit",
       %{tmp_dir: root} do
    h = setup_session(root, ["exec_command", "write_stdin"])
    pending = begin_run(h)

    input =
      exec(
        "printf 'eof\\n' >> effects; input=$(#{System.find_executable("cat")}); printf 'input=<%s>\\nafter-eof\\n' \"$input\"",
        0
      )

    pending = respond(h, pending, "eof-start", "exec_command", input)
    id = session_id(pending, "eof-start")

    pending =
      respond(h, pending, "eof-input", "write_stdin", %{
        "session_id" => id,
        "chars" => "first\nsecond\n",
        "eof" => true,
        "yield_time_ms" => 1000
      })

    finish(h, pending)
    {uses, results} = parts!(h)
    [_, result] = Enum.map(results, & &1.projection["result"])
    assert result["output"] == "input=<first\nsecond>\nafter-eof\n"
    assert result["command_id"] == id
    assert result["status"] == "completed"
    assert result["exit_code"] == 0
    assert result["cleanup_status"] == "confirmed"
    assert Map.has_key?(result, "session_id") == false
    assert File.read!(Path.join(root, "effects")) == "eof\n"
    assert_history(h, uses, results)
    replay(h, uses, results)
    assert File.read!(Path.join(root, "effects")) == "eof\n"
  end

  test "selected native inspection preserves running output, EOF completion, retained records and replay",
       %{tmp_dir: root} do
    h = setup_session(root, ["exec_command", "write_stdin", @process])
    pending = begin_run(h)

    command = """
    printf 'main\n' >> effects
    printf '%s' "$$" > main.pid
    while [[ ! -f emit.gate ]]; do #{System.find_executable("sleep")} 0.01; done
    printf 'alpha雪\n'
    printf ready > emitted
    input=$(#{System.find_executable("cat")})
    printf 'input=<%s>\npost-eof\n' "$input"
    """

    pending = respond(h, pending, "main-start", "exec_command", exec(command, 0))
    id = session_id(pending, "main-start")
    pid = root |> Path.join("main.pid") |> await_file() |> String.to_integer()
    File.touch!(Path.join(root, "emit.gate"))
    assert await_file(Path.join(root, "emitted")) == "ready"

    pending = inspect_call(h, pending, "running-list", %{"action" => "list"})
    [record] = response(pending, "running-list")["result"]
    assert record["command_id"] == id
    assert record["status"] == "running"
    assert record["finalized"] == false
    assert is_integer(record["started_at"])

    pending =
      inspect_call(h, pending, "running-inspect", %{"action" => "inspect", "command_id" => id})

    assert response(pending, "running-inspect")["result"] == record
    pending = inspect_call(h, pending, "log-one", %{"action" => "log", "command_id" => id})
    first = response(pending, "log-one")["result"]
    assert output(first) == "alpha雪\n"
    assert first["output_text"] == "alpha雪\n"
    assert first["cursor"] == byte_size("alpha雪\n")
    assert first["total_bytes"] == byte_size("alpha雪\n")
    assert first["truncated"] == false
    assert Map.has_key?(first, "output") == false
    pending = inspect_call(h, pending, "log-two", %{"action" => "log", "command_id" => id})
    assert response(pending, "log-two")["result"] == first
    pending = inspect_call(h, pending, "poll-one", %{"action" => "poll", "command_id" => id})
    assert response(pending, "poll-one")["result"] == first
    pending = inspect_call(h, pending, "poll-empty", %{"action" => "poll", "command_id" => id})
    empty = response(pending, "poll-empty")["result"]
    assert empty == %{first | "output_base64" => "", "output_text" => ""}

    pending =
      respond(h, pending, "native-delivery", "write_stdin", %{
        "session_id" => id,
        "yield_time_ms" => 0
      })

    pending =
      respond(h, pending, "native-input", "write_stdin", %{
        "session_id" => id,
        "chars" => "one\n",
        "yield_time_ms" => 0
      })

    pending =
      respond(h, pending, "native-eof", "write_stdin", %{
        "session_id" => id,
        "chars" => "two\n",
        "eof" => true,
        "yield_time_ms" => 1000
      })

    pending =
      inspect_call(h, pending, "finished-inspect", %{"action" => "inspect", "command_id" => id})

    final = response(pending, "finished-inspect")["result"]
    assert final["command_id"] == id
    assert final["finalized"] == true
    assert final["status"] == "completed"
    assert final["exit_status"] == 0
    assert final["cleanup_status"] == "confirmed"
    assert is_integer(final["finished_at"])
    await(fn -> not File.exists?("/proc/#{pid}") end)

    full = "alpha雪\ninput=<one\ntwo>\npost-eof\n"

    pending =
      inspect_call(h, pending, "finished-log", %{
        "action" => "log",
        "command_id" => id,
        "cursor" => 0
      })

    retained = response(pending, "finished-log")["result"]
    assert Map.drop(retained, ~w(output_base64 output_text cursor total_bytes truncated)) == final
    assert output(retained) == full
    assert retained["output_text"] == full
    assert retained["cursor"] == byte_size(full)
    assert retained["total_bytes"] == byte_size(full)
    assert retained["truncated"] == false
    pending = inspect_call(h, pending, "finished-poll", %{"action" => "poll", "command_id" => id})
    polled = response(pending, "finished-poll")["result"]

    assert polled == %{
             retained
             | "output_base64" => Base.encode64("input=<one\ntwo>\npost-eof\n"),
               "output_text" => "input=<one\ntwo>\npost-eof\n"
           }

    pending =
      respond(
        h,
        pending,
        "second-start",
        "exec_command",
        exec("printf 'second\\n' >> effects; printf 'second-done\\n'", 1000)
      )

    pending =
      respond(
        h,
        pending,
        "control-start",
        "exec_command",
        exec(
          "printf 'control\\n' >> effects; input=$(#{System.find_executable("cat")}); printf 'control=<%s>\\n' \"$input\"",
          0
        )
      )

    control = session_id(pending, "control-start")
    pending = inspect_call(h, pending, "three-records", %{"action" => "list"})
    records = response(pending, "three-records")["result"]
    assert length(records) == 3
    second = Enum.find(records, &(&1["command_id"] not in [id, control]))
    assert second["status"] == "completed"
    assert second["finalized"] == true
    assert Enum.find(records, &(&1["command_id"] == control))["status"] == "running"
    pending = inspect_call(h, pending, "remove-main", %{"action" => "remove", "command_id" => id})

    assert response(pending, "remove-main") == %{
             "action" => "remove",
             "result" => %{"removed" => true, "command_id" => id}
           }

    pending = inspect_call(h, pending, "after-remove", %{"action" => "list"})

    assert Enum.map(response(pending, "after-remove")["result"], & &1["command_id"]) ==
             Enum.sort([second["command_id"], control])

    pending = inspect_call(h, pending, "clear-finished", %{"action" => "clear_finished"})

    assert response(pending, "clear-finished") == %{
             "action" => "clear_finished",
             "result" => %{"removed" => 1}
           }

    pending = inspect_call(h, pending, "control-still-running", %{"action" => "list"})

    assert [%{"command_id" => ^control, "status" => "running", "finalized" => false}] =
             response(pending, "control-still-running")["result"]

    pending =
      respond(h, pending, "control-eof", "write_stdin", %{
        "session_id" => control,
        "chars" => "done\n",
        "eof" => true,
        "yield_time_ms" => 1000
      })

    pending =
      inspect_call(h, pending, "control-finished", %{
        "action" => "inspect",
        "command_id" => control
      })

    assert %{
             "command_id" => ^control,
             "status" => "completed",
             "finalized" => true,
             "cleanup_status" => "confirmed",
             "exit_status" => 0
           } = response(pending, "control-finished")["result"]

    finish(h, pending)

    {uses, results} = parts!(h)
    by_id = Map.new(results, &{&1.tool_use_id, &1})
    assert by_id["native-delivery"].projection["result"]["output"] == "alpha雪\n"
    assert by_id["native-input"].projection["result"]["output"] == ""
    eof = by_id["native-eof"].projection["result"]
    assert eof["command_id"] == id
    assert eof["output"] == "input=<one\ntwo>\npost-eof\n"
    assert eof["status"] == "completed"
    assert eof["cleanup_status"] == "confirmed"
    assert eof["exit_code"] == 0
    assert Map.has_key?(eof, "session_id") == false
    assert by_id["second-start"].projection["result"]["output"] == "second-done\n"
    assert by_id["control-eof"].projection["result"]["output"] == "control=<done>\n"

    for part <- results, String.starts_with?(part.tool_use_id, "inspection-") do
      assert Jason.decode!(part.content) == part.projection["result"]["structured"]
    end

    assert_history(h, uses, results)
    assert File.read!(Path.join(root, "effects")) == "main\nsecond\ncontrol\n"
    replay(h, uses, results)
    assert File.read!(Path.join(root, "effects")) == "main\nsecond\ncontrol\n"
  end

  defp setup_session(root, tools) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: tools})
    Agent.update(h.counter, &Map.merge(&1, %{reply: nil, expected_calls: []}))
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:inspection_request, index, request, self()})

      case AbortableHTTP.await(conn, :respond, 10_000, owner) do
        {:released, conn} ->
          case Agent.get(h.counter, & &1.reply) do
            {:call, id, name, args} ->
              DeterministicProvider.send_sse(conn, [
                DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
                DeterministicProvider.finish_chunk("tool_calls")
              ])

            :finish ->
              DeterministicProvider.send_sse(conn, [
                DeterministicProvider.text_chunk("Ordinary command inspection complete"),
                DeterministicProvider.finish_chunk("stop")
              ])
          end

        {_, conn} ->
          conn
      end
    end)

    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    Map.put(h, :selected_tools, tools)
  end

  defp begin_run(h) do
    assert :ok = Worker.send_message(h.session.id, "Inspect finite ordinary native commands")
    pending = {_, request, _} = receive_request(0)

    assert Enum.sort(Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort(h.selected_tools)

    stdin = Enum.find(request["tools"], &(&1["function"]["name"] == "write_stdin"))
    assert stdin["function"]["parameters"]["properties"]["eof"] == %{"type" => "boolean"}

    if @process in h.selected_tools do
      process =
        Enum.find(request["tools"], &(ToolName.decode(&1["function"]["name"]) == @process))

      assert process["function"]["parameters"]["properties"]["action"]["enum"] ==
               ~w(list inspect log poll remove clear_finished)
    end

    pending
  end

  defp receive_request(index) do
    assert_receive {:inspection_request, ^index, request, handler}, 10_000
    {index, request, handler}
  end

  defp respond(h, {index, _, handler}, id, name, args) do
    Agent.update(
      h.counter,
      &Map.merge(&1, %{
        reply: {:call, id, name, args},
        expected_calls: &1.expected_calls ++ [{id, name, args}]
      })
    )

    send(handler, :respond)
    pending = receive_request(index + 1)
    {_, request, _} = pending
    assert Enum.any?(tool_results(request), &(&1["tool_call_id"] == id))

    if name == @process do
      assert_receive {"tool_result", %{tool_use_id: ^id} = result}, 5000
      assert result.is_error == false, inspect(result.projection)
    end

    pending
  end

  defp inspect_call(h, pending, id, args),
    do: respond(h, pending, "inspection-" <> id, @process, args)

  defp response({_, request, _}, id) do
    request
    |> tool_results()
    |> Enum.find(&(&1["tool_call_id"] == "inspection-" <> id))
    |> Map.fetch!("content")
    |> Jason.decode!()
  end

  defp session_id({_, request, _}, id) do
    result = Enum.find(tool_results(request), &(&1["tool_call_id"] == id))
    assert [_, value] = Regex.run(~r/Session ID: (\d+)/, result["content"])
    String.to_integer(value)
  end

  defp finish(h, {_, _, handler}) do
    Agent.update(h.counter, &Map.put(&1, :reply, :finish))
    send(handler, :respond)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
  end

  defp exec(command, wait),
    do: %{
      "cmd" => command,
      "shell" => "/bin/bash",
      "login" => false,
      "tty" => false,
      "yield_time_ms" => wait,
      "max_output_tokens" => 1000
    }

  defp output(result), do: Base.decode64!(result["output_base64"])
  defp tool_results(request), do: Enum.filter(request["messages"], &(&1["role"] == "tool"))

  defp parts!(h) do
    parts =
      for message <- Synapsis.Message.list_by_session(h.session.id),
          part <- message.parts,
          match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
          do: part

    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))

    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) ==
             Agent.get(h.counter, & &1.expected_calls)

    assert Enum.map(uses, & &1.tool_use_id) == Enum.map(results, & &1.tool_use_id)
    assert Enum.all?(results, &(&1.is_error == false))

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    {uses, results}
  end

  defp assert_history(h, uses, results) do
    requests = Agent.get(h.counter, & &1.provider_requests)

    for {request, index} <- Enum.with_index(requests) do
      assert_wire(request, Enum.take(uses, index), Enum.take(results, index))
    end

    assert {:ok, turns} = Store.list_turns(h.session.id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(h.session.id, index))

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(raw, &(&1[:type] == "tool_use")) ==
             Enum.map(
               uses,
               &%{
                 type: "tool_use",
                 id: &1.tool_use_id,
                 name: &1.tool,
                 input: &1.input,
                 status: to_string(&1.status)
               }
             )

    assert Enum.filter(raw, &(&1[:type] == "tool_result")) ==
             Enum.map(
               results,
               &%{
                 type: "tool_result",
                 tool_use_id: &1.tool_use_id,
                 content: &1.content,
                 is_error: &1.is_error,
                 projection: &1.projection
               }
             )
  end

  defp assert_wire(request, uses, results) do
    calls = for message <- request["messages"], call <- message["tool_calls"] || [], do: call

    assert Enum.map(
             calls,
             &{&1["id"], ToolName.decode(&1["function"]["name"]),
              Jason.decode!(&1["function"]["arguments"])}
           ) == Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(tool_results(request), &{&1["tool_call_id"], &1["content"]}) ==
             Enum.map(results, &{&1.tool_use_id, &1.content})
  end

  defp replay(h, uses, results) do
    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(h.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    SessionHarness.ensure_running!(h.session.id)
    [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    assert new != old
    index = length(Agent.get(h.counter, & &1.provider_requests))
    assert :ok = Worker.send_message(h.session.id, "Recall the completed command inspection")
    pending = {_, request, _} = receive_request(index)
    assert_wire(request, uses, results)
    finish(h, pending)
    assert parts!(h) == {uses, results}
    assert_history(h, uses, results)
  end

  defp await_file(path) do
    await(fn -> match?({:ok, value} when byte_size(value) > 0, File.read(path)) end)
    File.read!(path)
  end

  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 5_000)

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline,
             "ordinary process observation did not arrive"

      Process.sleep(10)
      await(check, deadline)
    end
  end
end
