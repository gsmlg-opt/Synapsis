defmodule Synapsis.Agent.Tools.LLMTaskCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Goal, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{GoalStore, RunInventory, Store}
  alias Synapsis.Agent.Tools.LLMTask.{Completion, Request, Result}
  alias Synapsis.Goal.Store, as: GoalDataStore
  alias Synapsis.Runtime.Store, as: Journal

  @moduletag timeout: 60_000
  @system "You are a JSON-only function. Return ONLY a valid JSON value. Do not wrap in markdown fences. Do not include commentary. Do not call tools."
  @prepared "TASK:\nSummarize the supplied input as JSON.\n\nINPUT_JSON:\n{\n  \"value\": 7\n}\n"
  @usage %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3}
  @parent_usage %{input_tokens: 10, cached_tokens: 2, output_tokens: 3, reasoning_tokens: 1}
  @final_usage %{input_tokens: 12, cached_tokens: 3, output_tokens: 4, reasoning_tokens: 2}
  @next_usage %{input_tokens: 9, cached_tokens: 1, output_tokens: 2, reasoning_tokens: 1}
  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defmodule ParentProvider do
    def stream(request, %{observer: observer}) do
      send(observer, {:parent_request, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Hooks do
    def tool_effect_timeout(_invocation, _context), do: {:ok, 20_000}
  end

  defmodule GoalHost do
    @behaviour Backplane.AgentRuntime.Goal.Host

    def record_user_instruction(observer, thread_id, instruction) do
      send(observer, {:goal_instruction, thread_id, instruction})
      :ok
    end

    def start_turn_if_idle(_, _, _), do: raise("this fixture uses ordinary Session admission")
  end

  defmodule Backend do
    def execute(operation) do
      context = operation.backend_context
      send(context.observer, {:completion_operation, operation, self()})

      with {:ok, completion} <-
             Completion.run(context.request, Map.put(context, :operation, operation)),
           {:ok, presented} <- Result.present(completion.value) do
        {:ok, Map.put(presented, :completion, completion)}
      end
    end
  end

  test "one isolated native completion returns an object through the next parent request" do
    exercise("```json\n{\"answer\":7}\n```", %{"answer" => 7}, @schema, "{\n  \"answer\": 7\n}")
  end

  test "one isolated native completion returns an array through the next parent request" do
    exercise("[7,\"value\",true]", [7, "value", true], nil, "[\n  7,\n  \"value\",\n  true\n]")
  end

  test "one isolated native completion returns null through the next parent request" do
    exercise("null", nil, nil, "null")
  end

  test "an actual parent Goal receives one delegated charge and preserves ordinary parent continuity" do
    exercise(
      "```json\n{\"answer\":7}\n```",
      %{"answer" => 7},
      @schema,
      "{\n  \"answer\": 7\n}",
      true
    )
  end

  defp exercise(raw, expected, schema, expected_content, goal? \\ false) do
    :ok = Synapsis.Session.Store.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    {:ok, store} = Store.new(1)
    # ExUnit stops supervised fixture writers before running on_exit callbacks.
    on_exit(fn ->
      cleanup_journal(session_id, store.namespace)

      if goal? do
        assert :ok = Concord.Turso.delete("coord/goals/threads/" <> session_id, timeout: 5_000)
      end
    end)

    observer = self()
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:child_http_request, Jason.decode!(body), self()})

      receive do
        :respond ->
          chunks = [
            %{
              "choices" => [
                %{"index" => 0, "delta" => %{"content" => raw}, "finish_reason" => "stop"}
              ]
            },
            %{
              "choices" => [],
              "usage" => %{
                "prompt_tokens" => 20,
                "prompt_tokens_details" => %{"cached_tokens" => 6},
                "completion_tokens" => 8,
                "completion_tokens_details" => %{"reasoning_tokens" => 3},
                "total_tokens" => 28
              }
            }
          ]

          body =
            Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <>
              "data: [DONE]\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 5_000})

    authority = %{
      caller: "llm-completion-fixture",
      run_id: run_id,
      grants: ["fixture_completion"],
      tool_revisions: %{"fixture_completion" => 1}
    }

    assert {:ok, binding} = Session.bind(session, authority)
    goal = if goal?, do: start_goal(session_id, authority)

    resolved = %{
      timeout_ms: 15_000,
      output_limit: 65_536,
      provider_context: %{
        provider_config: %{
          type: "openai",
          base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
          api_key: "fixture"
        },
        request_options: %{model: "completion-fixture", max_tokens: 128, temperature: 0.2}
      }
    }

    task = %{
      "prompt" => "Summarize the supplied input as JSON.",
      "input" => %{"value" => 7},
      "schema" => schema
    }

    assert {:ok, request} = Request.prepare(task, resolved)
    assert request.prompt == @prepared
    assert request.provider_context === resolved.provider_context

    context = %{
      observer: self(),
      session_binding: binding,
      session_id: session_id,
      store: store,
      caller: authority.caller,
      request: request
    }

    descriptor = %{
      tool_name: "fixture_completion",
      tool_revision: 1,
      backend: Backend,
      backend_context: context,
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)

    options = [
      run_id: run_id,
      incarnation: 1,
      store: Store,
      context: store,
      provider: ParentProvider,
      provider_context: %{observer: self()},
      subscriber: self(),
      registry: registry,
      authority: authority,
      schema_admission: :strict,
      hooks: Hooks,
      session_binding: binding,
      work: 3,
      run_timeout: 30_000,
      effect_timeout: 20_000,
      commit_timeout: 5_000,
      cleanup_timeout: 5_000
    ]

    options = attach_goal(options, goal)

    parent = start_supervised!({Conversation, options})
    assert {:ok, _} = Conversation.prompt(parent, "PARENT TRANSCRIPT must stay in parent")
    assert_receive {:parent_request, initial, provider}, 5_000
    assert initial.run_id == run_id
    initial_content = if goal, do: "Preparing the isolated JSON subtask", else: ""

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "completion-call", name: "fixture_completion", arguments: %{}}
         },
         parent_response(initial_content, goal, @parent_usage)
       ]}
    )

    assert_receive {:completion_operation, operation, effect_owner}, 5_000
    assert_receive {:child_http_request, wire, fixture_pid}, 5_000
    assert wire["model"] == "completion-fixture"
    assert wire["max_tokens"] == 128
    assert wire["temperature"] == 0.2
    assert wire["tools"] in [nil, []]

    assert Enum.map(wire["messages"], &{&1["role"], text(&1)}) == [
             {"system", @system},
             {"user", @prepared}
           ]

    assert {:ok, [locator]} = Journal.list_facts(session_id, :run_locator)
    assert locator.kind == :llm_task
    assert locator.namespace == store.namespace
    assert locator.run_id != run_id
    assert locator.incarnation == 1
    assert locator.parent_run_id == run_id
    assert locator.parent_incarnation == 1
    assert locator.parent_invocation_id == operation.invocation_id
    assert operation.tool_call_id == "completion-call"

    assert {:ok, [%{id: resource_id, kind: :resource, status: :active}]} =
             ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)

    handle = %{
      resource_id: resource_id,
      owner_id: binding.owner_id,
      incarnation: binding.incarnation,
      kind: :llm_task
    }

    assert {:ok, child} =
             ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id)

    child_ref = Process.monitor(child)
    # Test-only observation of the native process tree; production uses public APIs.
    supervisor = :sys.get_state(child).supervisor
    supervisor_ref = Process.monitor(supervisor)
    child_status = Conversation.status(child)
    assert child_status.run.run_id == locator.run_id
    assert child_status.run.incarnation == locator.incarnation
    assert is_integer(child_status.run.deadline)
    assert child_status.run.deadline <= Conversation.status(parent).run.deadline
    assert {:links, links} = Process.info(child, :links)
    assert effect_owner in links

    if goal do
      assert operation.backend_context.goal == goal.pid
      assert operation.backend_context.goal_binding == goal.binding
      assert {:ok, parent_attribution} = Goal.attribution(goal.pid, goal.binding)
      assert parent_attribution == goal.binding
      assert_goal(goal, session_id, 11, @parent_usage, 1)

      # Pinned Backplane 1.10.52 source-private, read-only test observation.
      bindings = :sys.get_state(goal.pid).bindings
      assert map_size(bindings) == 2
      assert bindings[goal.binding.capability] == goal.binding
      [child_binding] = Enum.reject(Map.values(bindings), &(&1.run_id == run_id))
      assert child_binding.thread_id == locator.run_id
      assert child_binding.run_id == locator.run_id
      assert child_binding.incarnation == locator.incarnation
      assert child_binding.root_thread_id == session_id
      assert child_binding.root_goal_id == goal.id
      assert child_binding.expected_goal_id == goal.id
      assert child_binding.mode == goal.binding.mode
      assert child_binding.usage_authoritative == goal.binding.usage_authoritative
      assert child_binding.capability != goal.binding.capability
      assert child_binding.authority.run_id == locator.run_id
      assert child_binding.authority.caller == authority.caller
      assert child_binding.authority.grants == []
      assert child_binding.authority.tool_revisions == %{}
    end

    send(fixture_pid, :respond)

    assert_receive {:parent_request, next_request, next_provider}, 10_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}, 5_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, supervisor_reason}, 5_000
    assert supervisor_reason in [:normal, :shutdown]
    assert {:ok, []} = ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)
    assert Process.alive?(session)

    [result] =
      for %{role: :tool, tool_call_id: "completion-call", result: result} <-
            next_request.messages,
          do: result

    assert result.is_error == false
    assert result.completion.value == expected
    assert result.completion.text == raw
    assert result.completion.locator == locator
    assert result.completion.usage == @usage
    assert result.content == expected_content
    assert result.details == %{json: expected}
    assert Jason.decode!(result.content) == expected

    assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
    assert aggregate.run.state == :completed
    assert aggregate.run.incarnation == locator.incarnation
    assert aggregate.revision == aggregate.run.expected_revision
    assert aggregate.run.context.conversation.usage == [@usage, @usage]

    child_accounting =
      if goal do
        root =
          assert_goal(
            goal,
            session_id,
            33,
            %{
              input_tokens: 30,
              cached_tokens: 8,
              output_tokens: 11,
              reasoning_tokens: 4
            },
            2
          )

        assert {:ok, parent_attribution} = Goal.attribution(goal.pid, goal.binding)
        assert parent_attribution == goal.binding
        # Public run_completed follows acknowledged unbind; also observe live state.
        assert :sys.get_state(goal.pid).bindings == %{goal.binding.capability => goal.binding}
        assert aggregate.run.context.conversation.goal_outbox == []
        assert aggregate.run.context.conversation.goal_usage.totals == @usage
        assert map_size(aggregate.run.context.conversation.goal_usage.reports) == 1
        assert_child_accounting(root, locator)
      end

    assert List.last(aggregate.run.context.conversation.messages) == %{
             role: :assistant,
             content: [%{type: :text, text: raw}]
           }

    assert {:ok, parent_aggregate} = Journal.load(store.namespace, run_id)
    assert parent_aggregate.run.tool_results[operation.invocation_id].completion.value == expected
    assert parent_aggregate.run.tool_results[operation.invocation_id].content == expected_content
    assert parent_aggregate.run.tool_results[operation.invocation_id].details == %{json: expected}

    assert {:ok,
            %{
              coverage: :retained_only,
              entries: [%{locator: ^locator, aggregate: ^aggregate, availability: :present}]
            }} = RunInventory.load(session_id)

    send(
      next_provider,
      {:events, [parent_response("parent done", goal, @final_usage)]}
    )

    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000

    if goal do
      assert_parent_terminal(parent, store.namespace, run_id, goal)

      root =
        assert_goal(
          goal,
          session_id,
          46,
          %{
            input_tokens: 42,
            cached_tokens: 11,
            output_tokens: 15,
            reasoning_tokens: 6
          },
          3
        )

      assert root.turns == %{}
      assert assert_child_accounting(root, locator) == child_accounting
      assert Session.status(session).phase == :idle
    end

    next_id = Ecto.UUID.generate()
    next_authority = %{authority | run_id: next_id, grants: [], tool_revisions: %{}}
    assert {:ok, next_binding} = Session.bind(session, next_authority)
    next_goal = if goal, do: rebind_goal(goal, session_id, next_authority)

    next_options =
      options
      |> Keyword.put(:run_id, next_id)
      |> Keyword.put(:registry, %ToolRegistry{})
      |> Keyword.put(:authority, next_authority)
      |> Keyword.put(:session_binding, next_binding)
      |> attach_goal(next_goal)

    next_parent = start_supervised!({Conversation, next_options})
    assert {:ok, _} = Conversation.prompt(next_parent, "ordinary next parent work")
    assert_receive {:parent_request, %{run_id: ^next_id}, next_run_provider}, 5_000

    send(
      next_run_provider,
      {:events, [parent_response("next run done", goal, @next_usage)]}
    )

    assert_receive {:agent_runtime, ^next_id, %{type: :run_completed}}, 5_000

    if goal do
      assert_parent_terminal(next_parent, store.namespace, next_id, goal)

      root =
        assert_goal(
          goal,
          session_id,
          56,
          %{
            input_tokens: 51,
            cached_tokens: 12,
            output_tokens: 17,
            reasoning_tokens: 7
          },
          4
        )

      assert root.turns == %{}
      assert assert_child_accounting(root, locator) == child_accounting

      assert {:ok, ^root} =
               Task.async(fn -> GoalDataStore.load(session_id) end) |> Task.await(10_000)
    end

    assert {:ok, _} = Session.close(session)

    assert {:ok,
            %{coverage: :retained_only, entries: [%{locator: ^locator, aggregate: ^aggregate}]}} =
             RunInventory.load(session_id)

    Gaoxy.Test.verify!(fixture)
  end

  defp start_goal(session_id, authority) do
    goal =
      start_supervised!(
        {Goal,
         thread_id: session_id,
         owner_pid: self(),
         store: GoalStore,
         store_context: :local,
         host: GoalHost,
         host_context: self()}
      )

    instruction = %{text: "Complete the prepared JSON subtask"}

    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} =
             Goal.set(goal, %{objective: instruction.text}, instruction)

    assert_receive {:goal_instruction, ^session_id, ^instruction}
    assert {:ok, initial} = Goal.snapshot(goal)
    assert {:ok, ^initial} = GoalDataStore.load(session_id)
    assert initial.goal.token_budget == nil

    rebind_goal(%{pid: goal, id: initial.goal.goal_id}, session_id, authority)
  end

  defp rebind_goal(goal, session_id, authority) do
    assert {:ok, binding} =
             Goal.bind(goal.pid, %{
               thread_id: session_id,
               run_id: authority.run_id,
               incarnation: 1,
               authority: authority
             })

    assert binding.mode == :execution
    assert binding.usage_authoritative == false
    Map.put(goal, :binding, binding)
  end

  defp attach_goal(options, nil), do: options

  defp attach_goal(options, goal) do
    options
    |> Keyword.put(:goal, goal.pid)
    |> Keyword.put(:goal_binding, goal.binding)
    |> Keyword.put(:thread_id, goal.binding.thread_id)
  end

  defp parent_response(content, goal, usage) do
    event = %{type: :response_completed, message: %{role: :assistant, content: content}}
    if goal, do: Map.put(event, :usage, usage), else: event
  end

  defp assert_goal(goal, session_id, charge, totals, reports) do
    assert {:ok, root} = Goal.snapshot(goal.pid)
    assert root.thread_id == session_id
    assert root.goal.goal_id == goal.id
    assert root.goal.objective == "Complete the prepared JSON subtask"
    assert root.goal.status == :active
    assert root.goal.token_budget == nil
    assert root.goal.tokens_used == charge
    assert root.usage.totals == totals
    assert map_size(root.usage.reports) == reports
    assert map_size(root.usage_snapshots) == reports
    assert root.accounting_uncertain == false
    assert root.continuation_deferral == nil
    assert root.failure_turns == 0
    assert root.empty_turns == 0
    assert {:ok, ^root} = GoalDataStore.load(session_id)
    root
  end

  defp assert_child_accounting(root, locator) do
    child_attempt? = fn {{run, incarnation, _attempt}, _} ->
      run == locator.run_id and incarnation == locator.incarnation
    end

    baselines = Map.filter(root.baselines, child_attempt?)

    assert [{key, baseline}] = Map.to_list(baselines)
    assert is_binary(elem(key, 2)) and elem(key, 2) != ""
    assert baseline == %{input_tokens: 20, cached_tokens: 6, output_tokens: 8}
    usage_baselines = Map.filter(root.usage_baselines, child_attempt?)
    assert usage_baselines == baselines

    child_identity? = fn {identity, _} ->
      {run, incarnation, attempt, _snapshot} =
        identity |> Base.decode64!() |> :erlang.binary_to_term([:safe])

      {run, incarnation, attempt} == key
    end

    reports = Map.filter(root.usage.reports, child_identity?)
    snapshots = Map.filter(root.usage_snapshots, child_identity?)
    assert map_size(reports) == 1
    assert Map.keys(snapshots) == Map.keys(reports)

    receipts =
      Map.filter(root.receipts, fn {id, _} ->
        String.starts_with?(id, "#{locator.run_id}:#{locator.incarnation}:")
      end)

    assert map_size(receipts) > 0
    assert Enum.all?(Map.keys(receipts), &String.contains?(&1, ":usage:"))
    assert Enum.all?(Map.keys(root.turns), &(elem(&1, 0) != locator.run_id))

    %{
      baselines: baselines,
      usage_baselines: usage_baselines,
      reports: reports,
      snapshots: snapshots,
      receipts: receipts
    }
  end

  defp assert_parent_terminal(parent, namespace, run_id, goal) do
    status = Conversation.status(parent)
    assert status.phase == :terminal
    assert status.run.state == :completed
    assert status.resource_cleanup == :confirmed
    assert {:ok, aggregate} = Journal.load(namespace, run_id)
    assert aggregate.run.state == :completed
    assert aggregate.run.context.conversation.goal_outbox == []
    # Source-private read-only observation; public run_completed follows unbind ACK.
    assert :sys.get_state(goal.pid).bindings == %{}
  end

  defp text(%{"content" => content}) when is_binary(content), do: content

  defp text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp cleanup_journal(session_id, namespace) do
    prefixes = [
      "coord/runtime/facts/" <> segment(session_id) <> "/",
      "coord/runtime/runs/" <> segment(namespace) <> "/"
    ]

    for prefix <- prefixes do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
