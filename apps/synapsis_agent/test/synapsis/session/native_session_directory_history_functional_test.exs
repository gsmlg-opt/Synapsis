defmodule Synapsis.Session.NativeSessionDirectoryHistoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionDirectory
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Message

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::sessions_list"
  @call_id "directory-inline-history"

  test "revision three inline history retains source tool calls and exact JSON through HTTP, Concord and normal Worker reopen",
       %{tmp_dir: tmp_dir} do
    previous_node = Application.fetch_env(:synapsis_agent, :filesystem_node)
    node = node_executable()
    Application.put_env(:synapsis_agent, :filesystem_node, node)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case previous_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name]})
    archive = persist_archive()

    input = %{
      "search" => archive.id,
      "include_derived_titles" => true,
      "include_last_message" => true,
      "message_limit" => 3
    }

    install_provider(harness, input)
    observe_executions()
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Read the directory with inline history")
    initial = receive_request(0)
    assert_catalog(initial)
    assert_receive {:inline_history_selected, selected}, 5_000
    assert selected.tool_name == @name
    assert selected.tool_revision == 3
    assert selected.backend == SessionDirectory
    next = receive_request(1)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000

    {worker, adapter_pid, adapter} = runtime(harness.session.id)
    assert is_pid(adapter.session) and Process.alive?(adapter.session)
    {use, result} = assert_parts(harness.session.id, input, expected_page(archive))
    assert result.content == javascript_pretty(result.content, node)
    assert result.content =~ "\"fraction\": 1e-7"
    assert byte_size(result.content) <= 65_536

    assert byte_size(
             Jason.encode!(%{
               content: result.content,
               structured: result.projection["result"]["structured"]
             })
           ) <=
             262_144

    assert_wire_history(next, input, result)
    assert_runtime_result(adapter, result)
    assert [operation] = observed_executions()

    assert {operation.tool_name, operation.tool_call_id, operation.arguments} ==
             {@name, @call_id, input}

    assert operation.tool_revision == 3
    assert_archive(archive)

    assert :ok =
             Worker.send_message(harness.session.id, "Retain the completed directory observation")

    retained = receive_request(2)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_catalog(retained)
    assert_wire_history(retained, input, result)
    assert assert_parts(harness.session.id, input, expected_page(archive)) == {use, result}
    {^worker, ^adapter_pid, continued} = runtime(harness.session.id)
    assert continued.session == adapter.session
    assert continued.binding.owner_id == adapter.binding.owner_id
    assert continued.binding.incarnation == adapter.binding.incarnation
    assert continued.binding.resource_registry == adapter.binding.resource_registry
    assert_runtime_result(continued, result)
    assert observed_executions() == []

    stop_normally(harness.session.id, worker, adapter.session)
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the saved directory observation")
    replay = receive_request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_catalog(replay)
    assert_wire_history(replay, input, result)
    assert assert_parts(harness.session.id, input, expected_page(archive)) == {use, result}
    {^new_worker, _, replay_adapter} = runtime(harness.session.id)
    refute replay_adapter.session == adapter.session
    assert_runtime_result(replay_adapter, result)
    assert observed_executions() == []
    assert_archive(archive)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
    stop_normally(harness.session.id, new_worker, replay_adapter.session)
  end

  defp persist_archive do
    id = Ecto.UUID.generate()

    arguments = %{
      "path" => "reports/会議\"\\.md",
      "fraction" => 1.0e-7,
      "schema" => %{"type" => "object", "properties" => %{"tags" => %{"type" => "array"}}},
      "tags" => ["current", "published", "雪 😀\nsecond\u2028line"]
    }

    public = %{
      "content" => [%{"type" => "text", "text" => "Report body: 完了\nsecond line"}],
      "details" => %{"status" => "completed", "fraction" => 1.0e-7, "items" => [true, nil]},
      "structured" => %{"path" => arguments["path"], "schema" => arguments["schema"]},
      "is_error" => false
    }

    messages = [
      message("user", [%Text{content: "Read the published report."}]),
      message("assistant", [
        %Text{content: "Reading the published report."},
        %ToolUse{
          tool: "read_file",
          tool_use_id: "archive-report",
          input: arguments,
          status: :completed
        }
      ]),
      message("tool", [
        %ToolResult{
          tool_use_id: "archive-report",
          content: "Report body: 完了\nsecond line",
          projection: %{"version" => 1, "result" => public}
        }
      ]),
      message("assistant", [%Text{content: "The report is current. 雪 😀"}])
    ]

    meta = %{
      id: id,
      title: "saved host title",
      agent: "archive",
      provider: "archive-provider",
      model: "archive-model",
      status: "idle",
      inserted_at: "2026-11-06T00:00:00Z",
      updated_at: "2026-11-06T00:00:01Z"
    }

    assert :ok = Message.persist_list(id, messages, meta)
    on_exit(fn -> Store.delete_session(id) end)
    assert {:ok, raw} = Store.list_turns(id)
    %{id: id, meta: meta, messages: messages, arguments: arguments, public: public, raw: raw}
  end

  defp message(role, parts),
    do: %Message{
      id: Ecto.UUID.generate(),
      role: role,
      parts: parts,
      inserted_at: ~U[2026-11-06 00:00:00Z]
    }

  defp expected_page(archive) do
    [_, call, _, final] = archive.messages

    messages = [
      source_message(call, 2, [
        %{"type" => "text", "text" => "Reading the published report."},
        %{
          "type" => "toolCall",
          "id" => "archive-report",
          "name" => "read_file",
          "arguments" => archive.arguments
        }
      ]),
      source_message(final, 4, [%{"type" => "text", "text" => "The report is current. 雪 😀"}])
    ]

    # Pinned source first selects the three-row suffix, then strips the genuine
    # tool-role reply. It retains the assistant call and never backfills user.
    row =
      archive.meta
      |> json()
      |> Map.merge(%{
        "derived_title" => "Read the published report.",
        "last_message_preview" => "The report is current. 雪 😀",
        "messages" => messages
      })

    %{
      "source" => "durable",
      "count" => 1,
      "sessions" => [row],
      "has_more" => false,
      "limit_applied" => 100
    }
  end

  defp source_message(message, ordinal, content) do
    %{
      "role" => message.role,
      "timestamp" => DateTime.to_iso8601(message.inserted_at),
      "__openclaw" => %{"id" => message.id, "seq" => ordinal},
      "content" => content
    }
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

      send(owner, {:inline_history_request, index, request})

      chunks =
        if index == 0 do
          {_, _, adapter} = runtime(harness.session.id)
          selected = :sys.get_state(adapter.root, 1_000).catalog.registry.tools[@name]
          send(owner, {:inline_history_selected, selected})

          [
            DeterministicProvider.tool_call_chunk(ToolName.encode(@name), @call_id, input),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        else
          [
            DeterministicProvider.text_chunk("Directory history retained."),
            DeterministicProvider.finish_chunk("stop")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp receive_request(index) do
    assert_receive {:inline_history_request, ^index, request}, 15_000
    request
  end

  defp assert_catalog(request) do
    assert [descriptor] = request["tools"]
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    properties = descriptor["function"]["parameters"]["properties"]
    property = properties["message_limit"]
    assert property["type"] == "integer"
    assert property["minimum"] == 0
    assert property["default"] == 0
    refute Map.has_key?(property, "maximum")

    for flag <- ~w(include_derived_titles include_last_message),
        do: assert(properties[flag] == %{"type" => "boolean", "default" => false})
  end

  defp assert_wire_history(request, input, result) do
    actual =
      Enum.filter(request["messages"], &(Map.has_key?(&1, "tool_calls") or &1["role"] == "tool"))

    assert [call, reply] = actual

    assert call == %{
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
           }

    assert reply == %{"role" => "tool", "tool_call_id" => @call_id, "content" => result.content}
  end

  defp assert_parts(id, input, page) do
    messages = Message.list_by_session(id)
    parts = for message <- messages, part <- message.parts, do: part
    assert [use] = Enum.filter(parts, &match?(%ToolUse{}, &1))
    assert {use.tool, use.tool_use_id, use.input} == {@name, @call_id, input}
    assert [result] = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert result.tool_use_id == @call_id
    assert result.is_error == false
    assert Jason.decode!(result.content) == page

    assert result.projection == %{
             "version" => 1,
             "result" => %{"content" => result.content, "structured" => page, "is_error" => false}
           }

    assert Enum.filter(parts, &(match?(%ToolUse{}, &1) or match?(%ToolResult{}, &1))) == [
             use,
             result
           ]

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)
    assert turns == Enum.map(messages, &Message.encode/1)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    assert {:ok, replayed} = ProviderMessages.from_host(messages)
    assert [replayed_result] = Enum.filter(replayed, &(Map.get(&1, :tool_call_id) == @call_id))
    assert json(replayed_result.result) == result.projection["result"]
    {use, result}
  end

  defp assert_archive(archive) do
    assert Store.get_meta(archive.id) == {:ok, archive.meta}
    assert Store.list_turns(archive.id) == {:ok, archive.raw}
    assert Registry.lookup(Synapsis.Session.Registry, archive.id) == []
    [_, call, receipt, _] = Message.list_by_session(archive.id)
    assert List.last(call.parts).input == archive.arguments
    assert receipt.role == "tool"
    assert hd(receipt.parts).projection == %{"version" => 1, "result" => archive.public}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    {worker, data.runtime_pid, :sys.get_state(data.runtime_pid, 1_000)}
  end

  defp assert_runtime_result(adapter, result) do
    assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(adapter.store, adapter.run_id)
    messages = get_in(aggregate, [:run, :context, :conversation, :messages])
    assert [replayed] = Enum.filter(messages, &(&1[:role] == :tool))
    assert replayed.tool_call_id == @call_id
    assert json(replayed.result) == result.projection["result"]
  end

  defp stop_normally(id, worker, native) do
    worker_monitor = Process.monitor(worker)
    native_monitor = Process.monitor(native)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^native_monitor, :process, ^native, reason}, 5_000
    assert reason in [:normal, :shutdown]
  end

  defp observe_executions do
    Code.ensure_loaded!(SessionDirectory)
    assert :erlang.trace_pattern({SessionDirectory, :execute, 1}, true, [:local]) == 1
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({SessionDirectory, :execute, 1}, false, [:local])
    end)
  end

  defp observed_executions do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_executions([])
  end

  defp drain_executions(executions) do
    receive do
      {:trace, _, :call, {SessionDirectory, :execute, [operation]}} ->
        drain_executions([operation | executions])
    after
      0 -> Enum.reverse(executions)
    end
  end

  defp javascript_pretty(content, node) do
    script = ~S"""
    let input = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      input += chunk;
      const end = input.indexOf('\n');
      if (end < 0) return;
      process.stdout.write(JSON.stringify(JSON.parse(JSON.parse(input.slice(0, end))), null, 2));
      process.stdin.destroy();
    });
    """

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-e", script]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert Port.command(port, Jason.encode!(content) <> "\n")
    collect_pretty(port, "")
  end

  defp collect_pretty(port, output) do
    receive do
      {^port, {:data, chunk}} -> collect_pretty(port, output <> chunk)
      {^port, {:exit_status, 0}} -> output
    after
      5_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("ordinary JSON.stringify oracle did not finish")
    end
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
end
