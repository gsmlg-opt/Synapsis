defmodule Synapsis.Session.NativeSessionReadAdoptionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{SessionDirectory, SessionHistory, SessionStatus}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @directory "synapsis::sessions_list"
  @history "synapsis::sessions_history"
  @status "synapsis::session_status"
  @tools [@directory, @history, @status]
  @backends [SessionDirectory, SessionHistory, SessionStatus]
  @ids ~w(directory-first directory-last history-first history-last status-first status-retained)

  # Success-only qualification after official Concord 3.1.10 adoption.
  # Expected public fields follow the existing SessionDirectory/History/Status
  # contracts; no old-version failure or deadline-expiry claim is made here.
  setup do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)
    node = System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node")
    Application.put_env(:synapsis_agent, :filesystem_node, node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    :ok
  end

  test "durable native reads retain exact pages through next HTTP, another turn and fresh Worker replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @tools})

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    archive = seed_archive()
    calls = calls(archive)
    expected = expected_pages(archive)
    install_provider(harness, calls)
    trace_reads()
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert_archive(archive)

    assert :ok = Worker.send_message(harness.session.id, "Read the durable archive pages")
    requests = for index <- 0..5, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    {worker, adapter_pid, adapter} = runtime(harness.session.id)
    assert is_pid(adapter.session) and Process.alive?(adapter.session)

    {uses, results} =
      assert_parts(harness.session.id, Enum.take(calls, 5), Enum.take(expected, 5))

    for {request, count} <- Enum.with_index(requests) do
      assert_catalog(request)
      assert_wire_history(request, Enum.take(calls, count), Enum.take(results, count))
    end

    assert_runtime_results(adapter, results)
    first_calls = observed_calls()
    assert_executions(first_calls, Enum.take(calls, 5))
    assert_no_archive_hydration(first_calls, archive)
    assert_archive(archive)

    assert :ok = Worker.send_message(harness.session.id, "Observe the same durable archive again")
    before_retained = receive_request(6)
    retained = receive_request(7)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    {all_uses, all_results} = assert_parts(harness.session.id, calls, expected)
    assert_wire_history(before_retained, Enum.take(calls, 5), results)
    assert_wire_history(retained, calls, all_results)
    assert_catalog(before_retained)
    assert_catalog(retained)
    {^worker, ^adapter_pid, continued} = runtime(harness.session.id)
    assert continued.session == adapter.session
    assert continued.binding.owner_id == adapter.binding.owner_id
    assert continued.binding.incarnation == adapter.binding.incarnation
    assert continued.binding.resource_registry == adapter.binding.resource_registry
    refute continued.binding.run_id == adapter.binding.run_id
    assert Enum.take(all_uses, 5) == uses
    assert Enum.take(all_results, 5) == results
    assert_runtime_results(continued, all_results)
    next_calls = observed_calls()
    assert_executions(next_calls, [List.last(calls)])
    assert_no_archive_hydration(next_calls, archive)
    assert_archive(archive)

    worker_monitor = Process.monitor(worker)
    native_monitor = Process.monitor(adapter.session)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^native_monitor, :process, _, native_reason}, 5_000
    assert native_reason in [:normal, :shutdown]
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == worker

    assert :ok = Worker.send_message(harness.session.id, "Recall the saved archive observations")
    replay = receive_request(8)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_catalog(replay)
    assert_wire_history(replay, calls, all_results)
    assert assert_parts(harness.session.id, calls, expected) == {all_uses, all_results}
    {^new_worker, _, replay_adapter} = runtime(harness.session.id)
    refute replay_adapter.session == adapter.session
    assert_runtime_results(replay_adapter, all_results)
    replay_calls = observed_calls()
    assert_executions(replay_calls, [])
    assert_no_archive_hydration(replay_calls, archive)
    assert_archive(archive)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 9

    final_worker_monitor = Process.monitor(new_worker)
    final_native_monitor = Process.monitor(replay_adapter.session)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^final_worker_monitor, :process, ^new_worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^final_native_monitor, :process, _, final_native_reason}, 5_000
    assert final_native_reason in [:normal, :shutdown]
  end

  defp seed_archive do
    marker = "archive-#{Ecto.UUID.generate()}"
    agent = "archive-agent-#{Ecto.UUID.generate()}"

    records =
      for {year, owner} <- [{2026, agent}, {2025, agent}, {2024, "other-archive"}] do
        id = Ecto.UUID.generate()

        meta = %{
          id: id,
          title: "#{marker} 雪 #{year}",
          agent: owner,
          provider: "archive-provider",
          model: "archive-model",
          status: "idle",
          inserted_at: "2024-01-01T00:00:00Z",
          updated_at: "#{year}-01-01T00:00:00Z"
        }

        assert :ok = Store.put_meta(id, meta)
        on_exit(fn -> Store.delete_session(id) end)
        meta
      end

    target = hd(records)

    public_result = %{
      "content" => "归档成功 雪",
      "structured" => %{"value" => "αβ"},
      "is_error" => false
    }

    turns = [
      {0, %{role: "user", parts: [%{type: "text", text: "第一条消息 ☃"}]}},
      {7,
       %{
         role: "assistant",
         parts: [
           %{type: "text", text: "稀疏历史 Καλημέρα"},
           %{
             type: "tool_use",
             id: "archive-call",
             name: "archive::inspect",
             input: %{"label" => "雪", "items" => ["α", "β"]}
           },
           %{
             type: "tool_result",
             tool_use_id: "archive-call",
             content: "归档成功 雪",
             is_error: false,
             projection: %{"version" => 1, "result" => public_result}
           }
         ]
       }}
    ]

    for {index, turn} <- turns,
        do: assert(:ok = Store.commit_turn(target.id, index, turn, target))

    %{marker: marker, agent: agent, records: records, target: target, turns: turns}
  end

  defp calls(archive) do
    directory = %{
      "search" => String.upcase(archive.marker),
      "agent" => archive.agent,
      "limit" => 1
    }

    history = %{
      "session_id" => archive.target.id,
      "limit" => 1,
      "offset" => 0,
      "include_tools" => true
    }

    status = %{"session_id" => archive.target.id, "source" => "durable"}

    [
      {@directory, "directory-first", directory},
      {@directory, "directory-last", Map.put(directory, "offset", 1)},
      {@history, "history-first", history},
      {@history, "history-last", Map.put(history, "offset", 1)},
      {@status, "status-first", status},
      {@status, "status-retained", status}
    ]
  end

  defp expected_pages(archive) do
    [latest, older, _filtered] = archive.records
    [{0, first}, {7, last}] = archive.turns

    status = %{
      "source" => "durable",
      "session" => json(latest),
      "usage" =>
        json(%{
          source: "native_committed",
          coverage: "retained_runs",
          observation: "sequential",
          runtime_version: "1.10.60",
          retained_runs: 0,
          observed_runs: 0,
          provider_attempts: 0,
          metrics: %{input_tokens: 0, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0},
          cost: %{status: "unavailable"}
        })
    }

    [
      %{
        "source" => "durable",
        "count" => 1,
        "sessions" => [json(latest)],
        "has_more" => true,
        "limit_applied" => 1,
        "next_offset" => 1
      },
      %{
        "source" => "durable",
        "count" => 1,
        "sessions" => [json(older)],
        "has_more" => false,
        "limit_applied" => 1
      },
      history_page(archive.target.id, last, 2, 0),
      history_page(archive.target.id, first, 1, 1),
      status,
      status
    ]
  end

  defp history_page(id, turn, ordinal, offset) do
    content =
      Enum.map(turn.parts, fn part ->
        case part.type do
          "text" ->
            %{"type" => "text", "text" => part.text}

          "tool_use" ->
            %{
              "type" => "toolCall",
              "id" => part.id,
              "name" => part.name,
              "arguments" => part.input
            }

          "tool_result" ->
            part.projection["result"]
            |> Map.delete("is_error")
            |> Map.merge(%{
              "type" => "toolResult",
              "toolCallId" => part.tool_use_id,
              "isError" => part.is_error
            })
        end
      end)

    messages = [%{"role" => turn.role, "content" => content, "__openclaw" => %{"seq" => ordinal}}]
    pending = %{"items" => [], "total" => 0}

    page = %{
      "session_id" => id,
      "messages" => messages,
      "truncated" => false,
      "droppedMessages" => false,
      "contentTruncated" => false,
      "contentRedacted" => false,
      "bytes" => byte_size(Jason.encode!(messages)) + byte_size(Jason.encode!(pending)),
      "pendingInputs" => pending,
      "offset" => offset,
      "hasMore" => offset == 0,
      "totalMessages" => 2
    }

    if offset == 0, do: Map.put(page, "nextOffset", 1), else: page
  end

  defp assert_archive(archive) do
    for meta <- archive.records do
      assert Store.get_meta(meta.id) == {:ok, meta}
      assert Registry.lookup(Synapsis.Session.Registry, meta.id) == []
    end

    assert {:ok, page} = Store.list_turn_page(archive.target.id, limit: 100)

    assert page == %{
             turns: Enum.map(archive.turns, fn {index, turn} -> %{index: index, turn: turn} end),
             next_cursor: nil,
             has_more: false,
             truncated: false
           }

    for {index, turn} <- archive.turns,
        do: assert(Store.get_turn(archive.target.id, index) == {:ok, turn})
  end

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:session_read_request, index, request})
      call = if index < 5, do: Enum.at(calls, index), else: if(index == 6, do: List.last(calls))
      provider_response(conn, call)
    end)
  end

  defp provider_response(conn, call) do
    {content, delta, stop} =
      case call do
        {name, id, input} ->
          {%{"type" => "tool_use", "id" => id, "name" => ToolName.encode(name), "input" => %{}},
           %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}

        nil ->
          {%{"type" => "text", "text" => ""},
           %{"type" => "text_delta", "text" => "Durable archive inspected"}, "end_turn"}
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
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end

  defp receive_request(index) do
    assert_receive {:session_read_request, ^index, request}, 15_000
    request
  end

  defp assert_catalog(request) do
    assert request["tools"] |> Enum.map(&ToolName.decode(&1["name"])) |> Enum.sort() ==
             Enum.sort(@tools)
  end

  defp assert_wire_history(request, calls, results) do
    # Select whole tool-bearing messages, preserving every content block, role,
    # grouping and their combined order. Never compare two independent arrays.
    # assert_parts independently checks decoded text against exact expected pages;
    # the HTTP text must retain the complete persisted result bytes.
    assert length(calls) == length(results)

    actual =
      Enum.filter(request["messages"], fn message ->
        Enum.any?(
          List.wrap(message["content"]),
          &(is_map(&1) and &1["type"] in ["tool_use", "tool_result"])
        )
      end)

    assert actual ==
             Enum.flat_map(Enum.zip(calls, results), fn {{name, id, input}, result} ->
               [
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{
                       "type" => "tool_use",
                       "id" => id,
                       "name" => ToolName.encode(name),
                       "input" => input
                     }
                   ]
                 },
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "tool_result",
                       "tool_use_id" => id,
                       "is_error" => false,
                       "content" => [%{"type" => "text", "text" => result.content}]
                     }
                   ]
                 }
               ]
             end)
  end

  defp assert_parts(id, calls, pages) do
    messages = Synapsis.Message.list_by_session(id)
    parts = for message <- messages, part <- message.parts, do: part
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool, &1.tool_use_id, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.take(@ids, length(calls))

    assert Enum.filter(parts, &(match?(%ToolUse{}, &1) or match?(%ToolResult{}, &1))) ==
             Enum.flat_map(Enum.zip(uses, results), fn {use, result} -> [use, result] end)

    for {result, page} <- Enum.zip(results, pages) do
      assert result.is_error == false
      assert Jason.decode!(result.content) == page

      assert result.projection == %{
               "version" => 1,
               "result" => %{
                 "content" => result.content,
                 "structured" => page,
                 "is_error" => false
               }
             }
    end

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)
    assert length(turns) == length(messages)
    assert turns == Enum.map(messages, &Synapsis.Message.encode/1)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    {uses, results}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    {worker, data.runtime_pid, :sys.get_state(data.runtime_pid, 1_000)}
  end

  defp assert_runtime_results(adapter, parts) do
    assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(adapter.store, adapter.run_id)
    messages = get_in(aggregate, [:run, :context, :conversation, :messages])
    results = Enum.filter(messages, &(&1[:role] == :tool))
    assert Enum.map(results, & &1.tool_call_id) == Enum.map(parts, & &1.tool_use_id)

    for {message, part} <- Enum.zip(results, parts) do
      assert json(message.result) == part.projection["result"]
    end
  end

  defp trace_reads do
    for module <- @backends do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern({module, :execute, 1}, true, [:local]) == 1
    end

    Code.ensure_loaded!(Synapsis.Sessions)
    assert :erlang.trace_pattern({Synapsis.Sessions, :get, 1}, true, [:local]) == 1
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      for module <- @backends, do: :erlang.trace_pattern({module, :execute, 1}, false, [:local])
      :erlang.trace_pattern({Synapsis.Sessions, :get, 1}, false, [:local])
    end)
  end

  defp observed_calls do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_calls([])
  end

  defp drain_calls(calls) do
    receive do
      {:trace, _, :call, {module, function, args}} ->
        drain_calls([{module, function, args} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_executions(observed, expected) do
    executions =
      for {module, :execute, [operation]} <- observed, module in @backends, do: operation

    assert Enum.map(executions, &{&1.tool_name, &1.tool_call_id, &1.arguments}) == expected
  end

  defp assert_no_archive_hydration(observed, archive) do
    ids = Enum.map(archive.records, & &1.id)
    assert for({Synapsis.Sessions, :get, [id]} <- observed, id in ids, do: id) == []
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
