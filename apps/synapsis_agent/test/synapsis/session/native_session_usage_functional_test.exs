defmodule Synapsis.Session.NativeSessionUsageFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.Runtime.{RunInventory, SessionUsage}
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionStatus
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{Message, Part}

  @moduletag :tmp_dir
  @status "synapsis::session_status"
  @calls [
    {"usage-auto", %{}},
    {"usage-live", %{"source" => "live"}},
    {"usage-durable", %{"source" => "durable"}},
    {"usage-next-turn", %{"source" => "auto"}}
  ]

  # Every row is an independent provider observation. Expected aggregate values
  # below are literal sums; they are not derived from SessionUsage or raw native
  # snapshot enumeration. Trailing identical snapshots repeat a cumulative value.
  @chat_metrics [
    {11, 3, 5, 2},
    {17, 4, 7, 1},
    {23, 6, 9, 3},
    {31, 8, 11, 4},
    {37, 10, 13, 5},
    {41, 11, 17, 6},
    {43, 12, 19, 7}
  ]

  test "native status observes committed attempts once across continuations turns and ordinary fresh Worker replay",
       %{tmp_dir: root} do
    h = fixture(root)
    install_chat(h)
    observe_status_execution()
    id = h.session.id

    assert :ok = Worker.send_message(id, "Observe session usage first turn")
    requests = for index <- 0..3, do: request(index)
    await_completion(id)
    assert SessionUsage.read(id, deadline()) === {:ok, expected(1, 4, {82, 21, 32, 10})}

    first_results =
      assert_parts(id, Enum.take(@calls, 3), [
        expected(1, 1, {11, 3, 5, 2}),
        expected(1, 2, {28, 7, 12, 3}),
        expected(1, 3, {51, 13, 21, 6})
      ])

    assert Enum.map(first_results, &Jason.decode!(&1.content)["source"]) === [
             "live",
             "live",
             "durable"
           ]

    for {body, count} <- Enum.with_index(requests),
        do: assert_chat_history(body, Enum.take(first_results, count))

    assert Enum.map(status_executions(), & &1.invocation_id) |> Enum.uniq() |> length() === 3
    {worker, adapter} = runtime(id)
    assert adapter.goal_binding.expected_goal_id === nil
    first_native = aggregates(id)
    assert length(first_native) === 1
    assert_native_reports(first_native, [4])

    assert :ok = Worker.send_message(id, "Observe session usage next turn")
    request4 = request(4)
    request5 = request(5)
    await_completion(id)
    assert SessionUsage.read(id, deadline()) === {:ok, expected(2, 6, {160, 42, 62, 21})}

    all_results =
      assert_parts(id, @calls, [
        expected(1, 1, {11, 3, 5, 2}),
        expected(1, 2, {28, 7, 12, 3}),
        expected(1, 3, {51, 13, 21, 6}),
        expected(2, 5, {119, 31, 45, 15})
      ])

    assert Enum.take(all_results, 3) === first_results
    assert_chat_history(request4, first_results)
    assert_chat_history(request5, all_results)
    assert length(status_executions()) === 1
    assert runtime(id) |> elem(0) === worker
    before_recreation = aggregates(id)
    assert_native_reports(before_recreation, [2, 4])
    assert Enum.all?(first_native, &(&1 in before_recreation))
    journal_before = facts(id)
    messages_before = Message.list_by_session(id)
    assert aggregates(id) === before_recreation

    monitor = Process.monitor(worker)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 10_000
    assert facts(id) === journal_before
    assert aggregates(id) === before_recreation
    assert Message.list_by_session(id) === messages_before
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "Recall committed usage tool results")
    replay = request(6)
    await_completion(id)
    {fresh_worker, _fresh_adapter} = runtime(id)
    assert fresh_worker != worker
    assert_chat_history(replay, all_results)

    assert assert_parts(id, @calls, [
             expected(1, 1, {11, 3, 5, 2}),
             expected(1, 2, {28, 7, 12, 3}),
             expected(1, 3, {51, 13, 21, 6}),
             expected(2, 5, {119, 31, 45, 15})
           ]) === all_results

    assert status_executions() === []
    assert SessionUsage.read(id, deadline()) === {:ok, expected(3, 7, {203, 54, 81, 28})}
    assert Enum.all?(before_recreation, &(&1 in aggregates(id)))
    assert Enum.all?(journal_before.locators, &(&1 in facts(id).locators))
    assert Enum.all?(journal_before.attribution, &(&1 in facts(id).attribution))
    assert Enum.take(Message.list_by_session(id), length(messages_before)) === messages_before
    assert length(Agent.get(h.counter, & &1.provider_requests)) === 7

    # Explicit successful journal fixture: another retained locator incarnation
    # references the SAME real settled native aggregate address. This does not
    # claim a native execution at the synthetic locator incarnation. No further
    # owner startup/recovery follows this fixture; only read dedup is qualified.
    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    original_locator = hd(locators)
    duplicate = %{original_locator | incarnation: original_locator.incarnation + 100}
    native_before_duplicate = aggregates(id)
    assert :ok = RunInventory.retain(duplicate)
    assert {:ok, retained} = Journal.list_facts(id, :run_locator)
    assert length(retained) === length(locators) + 1
    observe_journal_loads()
    assert SessionUsage.read(id, deadline()) === {:ok, expected(3, 7, {203, 54, 81, 28})}

    assert Enum.sort(journal_loads()) ===
             Enum.sort(Enum.map(native_before_duplicate, &elem(&1, 0)))

    assert aggregates(id) === native_before_duplicate
    assert status_executions() === []
  end

  test "Anthropic inclusive input and read-cache subset remain known while absent reasoning stays null",
       %{tmp_dir: root} do
    h = fixture(root)

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "ordinary-fixture"
             })

    install_anthropic(h)
    id = h.session.id
    assert :ok = Worker.send_message(id, "Observe Anthropic committed usage")
    _initial = request(0)
    following = request(1)
    await_completion(id)
    assert SessionUsage.read(id, deadline()) === {:ok, expected(1, 2, {47, 11, 14, nil})}

    [result] =
      assert_parts(id, [{"anthropic-usage", %{"source" => "live"}}], [
        expected(1, 1, {30, 7, 5, nil})
      ])

    blocks =
      for message <- following["messages"],
          block <- List.wrap(message["content"]),
          is_map(block) and block["type"] == "tool_result",
          do: block

    assert blocks === [
             %{
               "type" => "tool_result",
               "tool_use_id" => "anthropic-usage",
               "is_error" => false,
               "content" => [%{"type" => "text", "text" => result.content}]
             }
           ]

    assert Jason.decode!(result.content)["usage"]["metrics"] === %{
             "input_tokens" => 30,
             "cached_tokens" => 7,
             "output_tokens" => 5,
             "reasoning_tokens" => nil
           }

    assert_native_reports(aggregates(id), [2])
    before = aggregates(id)
    assert SessionUsage.read(id, deadline()) === {:ok, expected(1, 2, {47, 11, 14, nil})}
    assert aggregates(id) === before
    assert length(Agent.get(h.counter, & &1.provider_requests)) === 2
  end

  defp fixture(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        agent_name: "native-usage-#{Ecto.UUID.generate()}",
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@status]})
    SessionHarness.subscribe!(h.session.id)
    h
  end

  defp expected(runs, attempts, {input, cached, output, reasoning}) do
    %{
      source: "native_committed",
      coverage: "retained_runs",
      observation: "sequential",
      runtime_version: "1.10.60",
      retained_runs: runs,
      observed_runs: runs,
      provider_attempts: attempts,
      metrics: %{
        input_tokens: input,
        cached_tokens: cached,
        output_tokens: output,
        reasoning_tokens: reasoning
      },
      cost: %{status: "unavailable"}
    }
  end

  defp install_chat(h) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:session_usage_request, index, request})

      call =
        case index do
          0 -> Enum.at(@calls, 0)
          1 -> Enum.at(@calls, 1)
          2 -> Enum.at(@calls, 2)
          4 -> Enum.at(@calls, 3)
          _ -> nil
        end

      response =
        case call do
          {id, input} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(@status), id, input),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Committed usage observed #{index}"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      usage = chat_usage(Enum.at(@chat_metrics, index))
      # These are repeated final cumulative snapshots, not additive deltas or
      # duplicated retired callbacks. Native records one report per attempt.
      DeterministicProvider.send_sse(conn, response ++ [usage, usage])
    end)
  end

  defp chat_usage({input, cached, output, reasoning}) do
    %{
      "choices" => [],
      "usage" => %{
        "prompt_tokens" => input,
        "completion_tokens" => output,
        "prompt_tokens_details" => %{"cached_tokens" => cached},
        "completion_tokens_details" => %{"reasoning_tokens" => reasoning},
        "total_tokens" => input + output
      }
    }
  end

  defp install_anthropic(h) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:session_usage_request, index, request})

      {input, read, write, output, content, delta, stop} =
        case index do
          0 ->
            {20, 7, 3, 5,
             %{
               "type" => "tool_use",
               "id" => "anthropic-usage",
               "name" => ToolName.encode(@status),
               "input" => %{}
             },
             %{
               "type" => "input_json_delta",
               "partial_json" => Jason.encode!(%{"source" => "live"})
             }, "tool_use"}

          1 ->
            {11, 4, 2, 9, %{"type" => "text", "text" => ""},
             %{"type" => "text_delta", "text" => "Anthropic usage observed"}, "end_turn"}
        end

      events = [
        %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{
              "input_tokens" => input,
              "cache_read_input_tokens" => read,
              "cache_creation_input_tokens" => write,
              "output_tokens" => 1
            }
          }
        },
        %{"type" => "content_block_start", "index" => 0, "content_block" => content},
        %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => stop},
          "usage" => %{"output_tokens" => output}
        },
        %{"type" => "message_delta", "usage" => %{"output_tokens" => output}},
        %{"type" => "message_stop"}
      ]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
    end)
  end

  defp assert_parts(id, calls, usages) do
    messages = Message.list_by_session(id)
    parts = for message <- messages, part <- message.parts, do: part
    uses = for %ToolUse{} = part <- parts, do: part
    results = for %ToolResult{} = part <- parts, do: part
    assert Enum.map(uses, &{&1.tool_use_id, &1.input}) === calls
    assert Enum.all?(uses, &(&1.tool == @status))
    assert Enum.map(results, & &1.tool_use_id) === Enum.map(calls, &elem(&1, 0))

    for {result, usage} <- Enum.zip(results, usages) do
      assert result.is_error === false
      decoded = Jason.decode!(result.content)
      assert decoded["session"]["id"] === id
      assert decoded["usage"] === json(usage)

      assert result.projection === %{
               "version" => 1,
               "result" => %{
                 "content" => result.content,
                 "structured" => decoded,
                 "is_error" => false
               }
             }

      assert {:ok, dumped} = Part.dump(result)
      assert {:ok, ^result} = dumped |> Jason.encode!() |> Jason.decode!() |> Part.load()
    end

    assert Store.list_turns(id) === {:ok, Enum.map(messages, &Message.encode/1)}
    results
  end

  defp assert_chat_history(request, results) do
    actual = for message <- request["messages"], message["role"] == "tool", do: message

    assert Enum.map(actual, &{&1["tool_call_id"], &1["content"]}) ===
             Enum.map(results, &{&1.tool_use_id, &1.content})
  end

  defp aggregates(id) do
    assert {:ok, locators} = Journal.list_facts(id, :run_locator)

    locators
    |> Enum.uniq_by(&{&1.namespace, &1.run_id})
    |> Enum.sort_by(&{&1.namespace, &1.run_id})
    |> Enum.map(fn locator ->
      assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
      {{locator.namespace, locator.run_id}, aggregate}
    end)
  end

  defp assert_native_reports(entries, expected_attempt_counts) do
    counts =
      for {_address, aggregate} <- entries do
        attempts = map_size(aggregate.run.provider_attempts)
        assert map_size(aggregate.run.context.conversation.goal_usage.reports) === attempts
        attempts
      end

    assert Enum.sort(counts) === Enum.sort(expected_attempt_counts)
  end

  defp facts(id) do
    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    assert {:ok, attribution} = Journal.list_facts(id, :goal_attribution)
    %{locators: Enum.sort(locators), attribution: Enum.sort(attribution)}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    {worker, :sys.get_state(data.runtime_pid)}
  end

  defp observe_status_execution do
    Code.ensure_loaded!(SessionStatus)
    assert :erlang.trace_pattern({SessionStatus, :execute, 1}, true, [:local]) === 1
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({SessionStatus, :execute, 1}, false, [:local])
    end)
  end

  defp status_executions do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_status([])
  end

  defp drain_status(acc) do
    receive do
      {:trace, _pid, :call, {SessionStatus, :execute, [operation]}} ->
        drain_status([operation | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp observe_journal_loads do
    Code.ensure_loaded!(Journal)
    assert :erlang.trace_pattern({Journal, :load, 2}, true, [:local]) === 1
    on_exit(fn -> :erlang.trace_pattern({Journal, :load, 2}, false, [:local]) end)
  end

  defp journal_loads do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_loads([])
  end

  defp drain_loads(acc) do
    receive do
      {:trace, _pid, :call, {Journal, :load, [namespace, run_id]}} ->
        drain_loads([{namespace, run_id} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp request(index) do
    assert_receive {:session_usage_request, ^index, request}, 15_000
    request
  end

  defp await_completion(id) do
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000

    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false, phase: "idle"}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
