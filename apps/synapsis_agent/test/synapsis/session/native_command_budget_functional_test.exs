defmodule Synapsis.Session.NativeCommandBudgetFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @call_ids ~w(budget-completed budget-start budget-poll budget-empty budget-omitted budget-input)
  @immediate %{
    "cmd" => "printf 'run\\n' >> budget-immediate-count.txt\nprintf 'A界B🙂C\\n'\n",
    "shell" => "/bin/bash",
    "login" => false,
    "tty" => false,
    "yield_time_ms" => 3000,
    "max_output_tokens" => 2
  }
  @command """
  printf 'run\\n' >> budget-process-count.txt
  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -f budget-output.gate ]] && break
    #{System.find_executable("sleep")} 0.01
  done
  [[ -f budget-output.gate ]] || exit 70
  printf 'A界B🙂C\\n'
  printf ready > budget-output.emitted
  IFS= read -r -t 15 value || exit 71
  printf 'stdin=%s\\n' "$value"
  """
  @running %{
    "cmd" => @command,
    "shell" => "/bin/bash",
    "login" => false,
    "tty" => false,
    "yield_time_ms" => 0,
    "max_output_tokens" => 2
  }
  @stdin_schema %{
    "type" => "object",
    "properties" => %{
      "session_id" => %{"type" => "number"},
      "chars" => %{"type" => "string"},
      "yield_time_ms" => %{"type" => "number"},
      "max_output_tokens" => %{"type" => "number"}
    },
    "required" => ["session_id"],
    "additionalProperties" => false
  }
  @exec_schema %{
    "type" => "object",
    "properties" => %{
      "cmd" => %{"type" => "string"},
      "workdir" => %{"type" => "string"},
      "tty" => %{"type" => "boolean"},
      "yield_time_ms" => %{"type" => "number"},
      "max_output_tokens" => %{"type" => "number"},
      "shell" => %{"type" => "string"},
      "login" => %{"type" => "boolean"},
      "sandbox_permissions" => %{
        "type" => "string",
        "enum" => ["use_default", "require_escalated"]
      },
      "justification" => %{"type" => "string"},
      "prefix_rule" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["cmd"],
    "additionalProperties" => false
  }

  test "Worker budgets UTF-8 exec and stdin responses once across polls, persistence and restart",
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
    assert :ok = Worker.send_message(harness.session.id, "Run the two budgeted local commands")

    assert_receive {:budget_request, 0, first}, 5_000
    assert_receive {:budget_request, 1, after_completed}, 5_000
    assert_receive {:budget_request, 2, started}, 5_000
    assert_receive {:budget_poll_waiting, handler}, 5_000
    session_id = session_id(started)
    assert is_integer(session_id) and session_id > 0

    # Exec has returned with no stdout. The one newline-terminated backend entry
    # is emitted only now; LocalCommand removes that newline before budgeting.
    File.touch!(Path.join(root, "budget-output.gate"))
    await_emission(Path.join(root, "budget-output.emitted"), 2_000)
    send(handler, :poll_budget_output)

    assert_receive {:budget_request, 3, after_budget}, 5_000
    assert_receive {:budget_request, 4, after_empty}, 5_000
    assert_receive {:budget_request, 5, after_omitted}, 5_000
    assert_receive {:budget_request, 6, following}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    inputs = [
      @immediate,
      @running,
      %{"session_id" => session_id, "yield_time_ms" => 100, "max_output_tokens" => 2},
      %{
        "session_id" => session_id,
        "chars" => "",
        "yield_time_ms" => 100,
        "max_output_tokens" => 2
      },
      %{"session_id" => session_id, "yield_time_ms" => 100},
      %{"session_id" => session_id, "chars" => "continued\n", "yield_time_ms" => 3000}
    ]

    parts = command_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @call_ids

    assert Enum.map(uses, & &1.tool) ==
             List.duplicate("exec_command", 2) ++ List.duplicate("write_stdin", 4)

    assert Enum.map(uses, & &1.input) == inputs
    assert Enum.map(results, & &1.tool_use_id) == @call_ids
    assert Enum.all?(results, &(&1.is_error == false))

    # Two estimated tokens allow eight bytes. The split emoji is removed too:
    # A(1) + 界(3) + B(1) survives; 🙂(4) + C(1) accounts for all five omitted bytes.
    assert byte_size("A界B🙂C") == 10
    assert byte_size("A界B") == 5

    expected = [
      {"A界B", "completed", 5},
      {"", "running", 0},
      {"A界B", "running", 5},
      {"", "running", 0},
      {"", "running", 0},
      {"stdin=continued", "completed", 0}
    ]

    for {part, {output, status, omitted}} <- Enum.zip(results, expected) do
      assert_command_result(part, output, status, omitted, session_id)
    end

    requests = [
      first,
      after_completed,
      started,
      after_budget,
      after_empty,
      after_omitted,
      following
    ]

    for {request, count} <- Enum.with_index(requests) do
      assert_selected_schemas(request)
      assert request["tools"] == first["tools"]
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable_parts(harness.session.id, uses, results)
    assert_once_only_effects(root)

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok = Worker.send_message(harness.session.id, "Recall the completed budgeted commands")
    assert_receive {:budget_request, 7, replay}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_selected_schemas(replay)
    assert replay["tools"] == first["tools"]
    assert_wire_history(replay, uses, results)
    assert command_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_once_only_effects(root)
    assert Agent.get(harness.counter, & &1.provider_requests) == requests ++ [replay]
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

      send(owner, {:budget_request, index, request})

      case index do
        0 ->
          call(conn, 0, "exec_command", @immediate)

        1 ->
          call(conn, 1, "exec_command", @running)

        2 ->
          send(owner, {:budget_poll_waiting, self()})

          case AbortableHTTP.await(conn, :poll_budget_output, 5_000, owner) do
            {:released, conn} ->
              call(conn, 2, "write_stdin", %{
                "session_id" => session_id(request),
                "yield_time_ms" => 100,
                "max_output_tokens" => 2
              })

            {_, conn} ->
              conn
          end

        3 ->
          call(conn, 3, "write_stdin", %{
            "session_id" => session_id(request),
            "chars" => "",
            "yield_time_ms" => 100,
            "max_output_tokens" => 2
          })

        4 ->
          call(conn, 4, "write_stdin", %{
            "session_id" => session_id(request),
            "yield_time_ms" => 100
          })

        5 ->
          call(conn, 5, "write_stdin", %{
            "session_id" => session_id(request),
            "chars" => "continued\n",
            "yield_time_ms" => 3000
          })

        _ ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("Budgeted commands complete"),
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

  defp assert_selected_schemas(request) do
    assert Enum.sort(Enum.map(request["tools"], &{&1["type"], &1["function"]["name"]})) ==
             [{"function", "exec_command"}, {"function", "write_stdin"}]

    schemas = Map.new(request["tools"], &{&1["function"]["name"], &1["function"]["parameters"]})
    assert schemas == %{"exec_command" => @exec_schema, "write_stdin" => @stdin_schema}
  end

  defp session_id(request) do
    started = Enum.find(tool_results(request), &(&1["tool_call_id"] == "budget-start"))
    [_, id] = Regex.run(~r/Session ID: (\d+)/, started["content"])
    String.to_integer(id)
  end

  defp assert_command_result(part, output, status, omitted, session_id) do
    raw = part.projection["result"]
    elapsed = raw["wall_time_seconds"]
    assert is_number(elapsed) and elapsed >= 0
    completed? = status == "completed"
    cleanup = if completed?, do: "confirmed", else: "not_started"

    lifecycle =
      if completed?,
        do: "Exit code: 0\n",
        else: "Session ID: #{session_id}\n"

    metadata =
      "Status: #{status}\n" <>
        lifecycle <>
        "Wall time: #{elapsed} seconds\n" <>
        "Termination: not_requested\n" <>
        "Cleanup: #{cleanup}\n" <>
        "Output truncated: #{omitted > 0}\n" <>
        "Omitted output bytes: #{omitted}\n" <>
        "Output budget unit: estimated_token_bytes\n" <>
        "Output limit exceeded: false"

    content = if output == "", do: metadata, else: output <> "\n\n" <> metadata

    expected = %{
      "output" => output,
      "status" => status,
      "termination_status" => "not_requested",
      "cleanup_status" => cleanup,
      "output_limit_exceeded?" => false,
      "wall_time_seconds" => elapsed,
      "output_truncated" => omitted > 0,
      "omitted_output_bytes" => omitted,
      "output_budget_unit" => "estimated_token_bytes",
      "is_error" => false,
      "content" => content
    }

    expected =
      if completed?,
        do: Map.put(expected, "exit_code", 0),
        else: Map.put(expected, "session_id", session_id)

    assert part.projection == %{"version" => 1, "result" => expected}
    assert part.content == content
    assert String.valid?(raw["output"])
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

  defp command_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
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

  defp assert_once_only_effects(root) do
    files = ["budget-immediate-count.txt", "budget-process-count.txt"]

    assert root |> File.ls!() |> Enum.filter(&String.ends_with?(&1, "-count.txt")) |> Enum.sort() ==
             files

    for file <- files, do: assert(File.read!(Path.join(root, file)) == "run\n")
  end

  defp await_emission(path, timeout) do
    await_emission_until(path, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_emission_until(path, deadline) do
    if File.read(path) == {:ok, "ready"} do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "local process did not emit its gated budget batch before the deadline"

      Process.sleep(10)
      await_emission_until(path, deadline)
    end
  end
end
