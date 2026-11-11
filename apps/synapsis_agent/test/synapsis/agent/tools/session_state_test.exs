defmodule Synapsis.Agent.Tools.SessionStateTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog
  }

  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.{ResultProjection, SessionState}
  alias Synapsis.Session.Store

  @read "synapsis::todo_read"
  @write "synapsis::todo_write"
  @names [@read, @write]

  setup do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, agent: "review", title: "Keep metadata"})
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{id}")
    on_exit(fn -> Store.delete_session(id) end)

    %{context: %{session_id: id, run_id: "/root/planner:1", incarnation: 1, catalog_revision: 1}}
  end

  test "fixed native descriptors have closed schemas, independent identities and honest safety",
       ctx do
    assert SessionState.names() == @names
    assert {:ok, [read, write] = descriptors} = SessionState.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == @names

    for descriptor <- descriptors do
      assert descriptor.backend == SessionState
      assert descriptor.backend_context === ctx.context
      assert descriptor.tool_revision === 1
      assert descriptor.schema["additionalProperties"] == false
      assert SessionState.permission_level(descriptor.tool_name) == :none

      assert {:error, %Error{}} =
               InputSchema.validate(descriptor.schema, %{"session_id" => Ecto.UUID.generate()})
    end

    assert read.safety == %{read_only: true, retry_safe: true, parallel_safe: true}

    assert write.safety == %{read_only: false, retry_safe: false, parallel_safe: false}

    assert write.schema["properties"]["todos"]["maxItems"] == 100
    assert write.schema["properties"]["todos"]["items"]["additionalProperties"] == false

    assert write.schema["properties"]["todos"]["items"]["properties"]["content"]["maxLength"] ==
             8192

    assert {:ok, _} =
             ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
  end

  test "classification selects the exact persisted session independently from opaque child run",
       ctx do
    for {name, action, suffix, arguments} <- [
          {@read, "session.todo.read", "todos", %{}},
          {@write, "session.todo.write", "todos", %{"todos" => []}}
        ] do
      assert {:ok, %{action: ^action, resource: resource}} =
               SessionState.classify(ctx.context, operation(ctx, name, arguments))

      assert resource == "session:#{ctx.context.session_id}:#{suffix}"
      refute resource =~ ctx.context.run_id
    end

    for run_id <- ["/root/研究者/child:2", "opaque:run"] do
      child = put_in(ctx.context.run_id, run_id)
      assert {:ok, _} = SessionState.descriptors(child.context)
      assert {:ok, _} = SessionState.execute(operation(child, @read, %{}))
    end
  end

  test "todo replacement preserves client IDs and list order in one durable value then broadcasts",
       ctx do
    todos = [todo("client-b", "Second", "completed"), todo("client-a", "First")]

    assert {:ok, %{content: "Updated 2 todo(s).", structured: %{count: 2}} = result} =
             SessionState.execute(operation(ctx, @write, %{"todos" => todos}))

    assert_receive {:todo_update, id, records}
    assert id == ctx.context.session_id
    assert records == Store.get_value(id, "todos")

    assert [
             %{
               "todo_id" => "client-b",
               "content" => "Second",
               "status" => "completed",
               "sort_order" => 0
             },
             %{
               "todo_id" => "client-a",
               "content" => "First",
               "status" => "pending",
               "sort_order" => 1
             }
           ] = records

    assert {:ok, _} = ResultProjection.to_part("write-call", result, tool_name: @write)
    refute_receive {:todo_update, _, _}

    assert {:ok, _} = SessionState.execute(operation(ctx, @write, %{"todos" => []}))
    assert Store.get_value(id, "todos") == []
    assert_receive {:todo_update, ^id, []}
  end

  @tag :model_visible_result
  test "todo reads sort existing records and expose portable id content status and order", ctx do
    records = [
      %{"todo_id" => "later", "content" => "Later", "status" => "completed", "sort_order" => 8},
      %{"todo_id" => "first", "content" => "First", "sort_order" => 2}
    ]

    :ok = Store.put_value(ctx.context.session_id, "todos", records)

    assert {:ok, %{structured: %{todos: [first, later]}} = result} =
             SessionState.execute(operation(ctx, @read, %{}))

    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    assert first == %{id: "first", content: "First", status: "pending", sort_order: 2}
    assert later == %{id: "later", content: "Later", status: "completed", sort_order: 8}
    assert {:ok, _} = ResultProjection.to_part("read-call", result, tool_name: @read)
    refute_receive {:todo_update, _, _}
  end

  @tag :model_visible_result
  test "todo reads apply the existing output budget to content and structured together", ctx do
    for {size, accepted?} <- [{4000, true}, {6000, false}] do
      todos = Enum.map(1..100, &todo(Integer.to_string(&1), String.duplicate("x", size)))

      assert {:ok, %{structured: %{count: 100}}} =
               SessionState.execute(operation(ctx, @write, %{"todos" => todos}))

      assert_receive {:todo_update, _, records}
      assert byte_size(Jason.encode!(%{todos: todos})) < 1_048_576

      if accepted? do
        assert {:ok, result} = SessionState.execute(operation(ctx, @read, %{}))
        assert byte_size(Jason.encode!(result)) <= 1_048_576
        assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
        assert length(Jason.decode!(result.content)["todos"]) == 100
      else
        assert {:error, %Error{class: :budget_exceeded, details: %{code: "output_limit"}}} =
                 SessionState.execute(operation(ctx, @read, %{}))
      end

      assert Store.get_value(ctx.context.session_id, "todos") == records
    end
  end

  test "missing sessions never become empty successful reads or orphan writes", ctx do
    missing = put_in(ctx.context.session_id, Ecto.UUID.generate())
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{missing.context.session_id}")

    for {name, args} <- [
          {@read, %{}},
          {@write, %{"todos" => [todo("a", "A")]}}
        ] do
      assert {:error, %Error{class: :not_found}} =
               SessionState.execute(operation(missing, name, args))
    end

    assert Store.get_value(missing.context.session_id, "todos") == nil
    refute_receive {:todo_update, _, _}
  end

  test "complete validation precedes replacement and rejects model authority selectors", ctx do
    assert {:ok, _} =
             SessionState.execute(operation(ctx, @write, %{"todos" => [todo("keep", "Keep")]}))

    assert_receive {:todo_update, _, original}

    for args <- [
          %{},
          %{"todos" => nil},
          %{"todos" => [todo("a", "A"), todo("a", "Duplicate")]},
          %{"todos" => [todo("valid", "Valid"), todo("bad", String.duplicate("a", 8193))]},
          %{"todos" => Enum.map(1..101, &todo(Integer.to_string(&1), "A"))},
          %{"todos" => [todo("a", "A", "unknown")]},
          %{"todos" => [Map.put(todo("a", "A"), "sort_order", 9)]},
          %{"todos" => [todo("", "A")]},
          %{"todos" => [todo("a", <<255>>)]},
          %{"todos" => [], "session_id" => Ecto.UUID.generate()}
        ] do
      assert {:error, %Error{class: :validation}} =
               SessionState.execute(operation(ctx, @write, args))

      assert Store.get_value(ctx.context.session_id, "todos") == original
    end

    for selector <- ["session_id", "run_id", "root", "backend"] do
      assert {:error, %Error{class: :validation}} =
               SessionState.execute(operation(ctx, @read, %{selector => "other"}))
    end

    refute_receive {:todo_update, _, _}
  end

  test "storage admission failures preserve prior data and emit no success events", ctx do
    prior = Application.get_env(:concord, :kv)
    Application.put_env(:concord, :kv, Keyword.put(prior || [], :max_value_bytes, 1))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:concord, :kv, prior),
        else: Application.delete_env(:concord, :kv)
    end)

    assert {:error, %Error{class: :execution_failure, details: %{code: "storage_failed"}}} =
             SessionState.execute(operation(ctx, @write, %{"todos" => [todo("a", "A")]}))

    assert {:ok, %{agent: "review"}} = Store.get_meta(ctx.context.session_id)
    assert Store.get_value(ctx.context.session_id, "todos") == nil
    refute_receive {:todo_update, _, _}
  end

  test "exact invocation fencing and only documented runtime context enrichment", ctx do
    op = operation(ctx, @read, %{})

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 1.0
        ] do
      assert {:error, :scope_mismatch} =
               SessionState.classify(ctx.context, Map.put(op, key, value))

      assert {:error, %Error{class: :forbidden}} = SessionState.execute(Map.put(op, key, value))
    end

    foreign = put_in(op.backend_context.session_id, Ecto.UUID.generate())
    assert {:error, :scope_mismatch} = SessionState.classify(ctx.context, foreign)

    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :root, "/"),
          %{ctx.context | session_id: "not-a-uuid"},
          %{ctx.context | run_id: ""},
          %{ctx.context | run_id: "bad\0run"},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0}
        ] do
      assert {:error, %Error{class: :validation}} = SessionState.descriptors(context)
    end

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> :unused end,
        emit: fn _ -> :unused end,
        resource_owner_pid: self(),
        goal: nil,
        goal_binding: nil
      })

    assert {:ok, _} = SessionState.execute(%{op | backend_context: enriched})

    assert {:error, :invalid_context} =
             SessionState.classify(enriched, %{op | backend_context: enriched})

    assert {:error, %Error{class: :validation}} =
             SessionState.execute(%{op | backend_context: Map.put(enriched, :store, Store)})

    assert {:error, %Error{class: :validation}} = SessionState.execute(nil)
    assert :ok = SessionState.cancel(op)
  end

  test "native Execution rejects grants revisions and schemas before session writes", ctx do
    {:ok, descriptors} = SessionState.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))
    {:ok, budget} = Budget.new(%{work: 2})

    input =
      operation(ctx, @write, %{"todos" => [todo("native", "Native")]})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    record = %{
      run_id: ctx.context.run_id,
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step", attempt_id: "attempt"},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }

    opts = [
      registry: bundle.registry,
      authority: authority(ctx),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2000,
      cleanup_timeout: 500
    ]

    for {changed_input, changed_opts} <- [
          {input, Keyword.put(opts, :authority, %{authority(ctx) | grants: []})},
          {%{input | tool_revision: 2}, opts},
          {%{input | arguments: Map.put(input.arguments, "session_id", Ecto.UUID.generate())},
           opts}
        ] do
      {:ok, table} = EphemeralStore.new(1)

      assert {:error, %Error{}} =
               Execution.run(
                 EphemeralStore,
                 table,
                 record,
                 %{command: {:tool_invoked, 11, changed_input}},
                 changed_opts
               )

      assert :ets.tab2list(table) == []
      assert Store.get_value(ctx.context.session_id, "todos") == nil
    end

    refute_receive {:todo_update, _, _}

    {:ok, table} = EphemeralStore.new(1)

    assert {:ok, _, %{effects: [%{structured: %{count: 1}}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               opts
             )

    assert_receive {:todo_update, _, [%{"todo_id" => "native"}]}
  end

  test "native Conversation executes both tools using runtime-enriched hierarchical scope",
       ctx do
    {:ok, descriptors} = SessionState.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))

    calls = [
      {@write, %{"todos" => [todo("conversation", "Plan it")]}},
      {@read, %{}}
    ]

    script = fn request ->
      index = Enum.count(request.messages, &(&1.role == :tool))

      case Enum.at(calls, index) do
        {name, args} ->
          [
            put_in(Proof.call(name, args), [:tool_call, :id], "call-#{index}"),
            Proof.completed("Working")
          ]

        nil ->
          [Proof.completed("Done")]
      end
    end

    opts =
      Proof.options(ctx.context.run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        work: 12
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Track the todo list")
    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3000

    assert [write, read] =
             Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))

    for message <- [write, read],
        do: refute(Map.get(message.result, :is_error, false))

    assert read.result.structured.todos == [
             %{id: "conversation", content: "Plan it", status: "pending", sort_order: 0}
           ]

    assert {:ok, %{agent: "review"}} = Store.get_meta(ctx.context.session_id)
  end

  defp todo(id, content, status \\ "pending"),
    do: %{"id" => id, "content" => content, "status" => status}

  defp authority(ctx),
    do: %{
      caller: "session-state-test",
      run_id: ctx.context.run_id,
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

  defp operation(ctx, name, arguments),
    do: %{
      tool_name: name,
      tool_revision: 1,
      arguments: arguments,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context
    }
end
