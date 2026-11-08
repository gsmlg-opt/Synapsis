defmodule Synapsis.Session.NativePtyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @call_ids ~w(pty-start pty-prompt pty-input pty-interrupt)
  @command """
  printf 'run\\n' >> process-count.txt
  [[ -t 0 && -t 1 && -t 2 ]] || exit 70
  #{System.find_executable("stty")} -echo
  printf '%s' "$$" > command.pid
  #{System.find_executable("sleep")} 30 &
  printf '%s' "$!" > descendant.pid
  trap 'printf "interrupt=received\\n"; exit 0' INT
  printf ready > process.ready
  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -f prompt.gate ]] && break
    #{System.find_executable("sleep")} 0.01
  done
  [[ -f prompt.gate ]] || exit 71
  printf 'tty=stdin,stdout,stderr\\n'
  #{System.find_executable("stty")} size
  printf 'prompt=雪>'
  printf ready > prompt.emitted
  IFS= read -r -t 15 value || exit 72
  printf 'stdin=%s\\n' "$value"
  printf ready > interrupt.ready
  while :; do #{System.find_executable("sleep")} 0.05; done
  """
  @exec %{
    "cmd" => @command,
    "shell" => "/bin/bash",
    "login" => false,
    "tty" => true,
    "yield_time_ms" => 0,
    "max_output_tokens" => 1000
  }

  test "Worker uses a real PTY and preserves terminal interaction through wire, Concord and restart",
       %{
         tmp_dir: root
       } do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: ["exec_command", "write_stdin"]
             })

    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Use the local terminal interactively")

    assert_receive {:pty_request, 0, first}, 5_000

    assert Enum.sort(Enum.map(first["tools"], & &1["function"]["name"])) ==
             ["exec_command", "write_stdin"]

    assert_receive {:pty_request, 1, started}, 5_000
    assert_receive {:prompt_waiting, handler}, 5_000
    session_id = session_id(started)
    await_file(root, "process.ready")
    processes = process_identities!(root)
    File.touch!(Path.join(root, "prompt.gate"))
    await_file(root, "prompt.emitted")
    send(handler, :poll_prompt)

    assert_receive {:pty_request, 2, after_prompt}, 5_000
    assert_receive {:pty_request, 3, after_input}, 5_000
    assert_receive {:interrupt_waiting, handler}, 5_000
    await_file(root, "interrupt.ready")
    send(handler, :interrupt)

    assert_receive {:pty_request, 4, following}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    parts = process_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @call_ids
    assert Enum.map(uses, & &1.tool) == ["exec_command" | List.duplicate("write_stdin", 3)]

    assert Enum.map(uses, & &1.input) == [
             @exec,
             %{"session_id" => session_id, "chars" => "", "yield_time_ms" => 100},
             %{"session_id" => session_id, "chars" => "continued-é\n", "yield_time_ms" => 1000},
             %{"session_id" => session_id, "chars" => "\u0003", "yield_time_ms" => 1000}
           ]

    assert Enum.map(results, & &1.tool_use_id) == @call_ids
    assert Enum.all?(results, &(&1.is_error == false))
    native = Enum.map(results, & &1.projection["result"])

    assert Enum.map(native, & &1["output"]) == [
             "",
             "tty=stdin,stdout,stderr\r\n24 80\r\nprompt=雪>",
             "stdin=continued-é\r\n",
             "interrupt=received\r\n"
           ]

    assert Enum.map(native, & &1["status"]) == ["running", "running", "running", "completed"]
    assert Enum.map(Enum.take(native, 3), & &1["session_id"]) == List.duplicate(session_id, 3)
    assert List.last(native)["exit_code"] == 0
    refute Map.has_key?(List.last(native), "session_id")
    await(fn -> Enum.all?(processes, &exited?/1) end, deadline())

    assert_wire_history(after_prompt, Enum.take(uses, 2), Enum.take(results, 2))
    assert_wire_history(after_input, Enum.take(uses, 3), Enum.take(results, 3))
    assert_wire_history(following, uses, results)

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable_parts(harness.session.id, uses, results)
    assert File.read!(Path.join(root, "process-count.txt")) == "run\n"
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok =
             Worker.send_message(harness.session.id, "Recall the completed terminal interaction")

    assert_receive {:pty_request, 5, replay}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_history(replay, uses, results)
    assert process_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert File.read!(Path.join(root, "process-count.txt")) == "run\n"
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 6
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:pty_request, index, request})

      case index do
        0 ->
          call(conn, 0, "exec_command", @exec)

        1 ->
          send(owner, {:prompt_waiting, self()})

          case AbortableHTTP.await(conn, :poll_prompt, 5_000, owner) do
            {:released, conn} ->
              call(conn, 1, "write_stdin", %{
                "session_id" => session_id(request),
                "chars" => "",
                "yield_time_ms" => 100
              })

            {_, conn} ->
              conn
          end

        2 ->
          call(conn, 2, "write_stdin", %{
            "session_id" => session_id(request),
            "chars" => "continued-é\n",
            "yield_time_ms" => 1000
          })

        3 ->
          send(owner, {:interrupt_waiting, self()})

          case AbortableHTTP.await(conn, :interrupt, 5_000, owner) do
            {:released, conn} ->
              call(conn, 3, "write_stdin", %{
                "session_id" => session_id(request),
                "chars" => "\u0003",
                "yield_time_ms" => 1000
              })

            {_, conn} ->
              conn
          end

        _ ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("Terminal complete"),
            DeterministicProvider.finish_chunk("stop")
          ])
      end
    end)
  end

  defp call(conn, index, name, input) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.tool_call_chunk(
        ToolName.encode(name),
        Enum.at(@call_ids, index),
        input
      ),
      DeterministicProvider.finish_chunk("tool_calls")
    ])
  end

  defp session_id(request) do
    first = Enum.find(tool_results(request), &(&1["tool_call_id"] == hd(@call_ids)))
    [_, id] = Regex.run(~r/Session ID: (\d+)/, first["content"])
    String.to_integer(id)
  end

  defp tool_results(request), do: Enum.filter(request["messages"], &(&1["role"] == "tool"))

  defp assert_wire_history(request, uses, results) do
    calls = for message <- request["messages"], call <- message["tool_calls"] || [], do: call

    assert Enum.map(calls, fn call ->
             {call["id"], ToolName.decode(call["function"]["name"]),
              Jason.decode!(call["function"]["arguments"])}
           end) == Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(tool_results(request), &{&1["tool_call_id"], &1["content"]}) ==
             Enum.map(results, &{&1.tool_use_id, &1.content})
  end

  defp process_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)
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

  defp process_identities!(root) do
    command = identity!(read_pid(root, "command.pid"))
    descendant = identity!(read_pid(root, "descendant.pid"))
    guardian = identity!(command.parent)
    broker = identity!(guardian.parent)

    for helper <- [guardian, broker] do
      assert File.read_link!("/proc/#{helper.pid}/exe") =~ "backplane-local-command-pty"
    end

    assert descendant.parent == command.pid
    [command, descendant, guardian, broker]
  end

  defp read_pid(root, name), do: root |> Path.join(name) |> File.read!() |> String.to_integer()

  defp identity!(pid) do
    [_comm, fields] = File.read!("/proc/#{pid}/stat") |> String.split(") ", parts: 2)
    fields = String.split(fields)
    %{pid: pid, parent: String.to_integer(Enum.at(fields, 1)), start: Enum.at(fields, 19)}
  end

  defp exited?(identity) do
    case File.read("/proc/#{identity.pid}/stat") do
      {:error, :enoent} ->
        true

      {:ok, stat} ->
        [_comm, fields] = String.split(stat, ") ", parts: 2)
        fields = String.split(fields)
        Enum.at(fields, 19) != identity.start or hd(fields) in ["Z", "X"]

      _ ->
        false
    end
  end

  defp await_file(root, name) do
    await(fn -> File.read(Path.join(root, name)) == {:ok, "ready"} end, deadline())
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline, "PTY lifecycle observation timed out"
      Process.sleep(10)
      await(check, deadline)
    end
  end
end
