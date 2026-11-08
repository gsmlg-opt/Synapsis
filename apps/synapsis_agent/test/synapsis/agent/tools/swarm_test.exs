defmodule Synapsis.Agent.Tools.SwarmTest do
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
  alias Synapsis.Agent.Tools.{ResultProjection, Swarm}

  @message "synapsis::swarm_message"
  @teammate "synapsis::teammate"
  @delete "synapsis::team_delete"
  @names [@message, @teammate, @delete]
  @table :synapsis_swarm_teammates

  setup do
    context = %{
      session_id: Ecto.UUID.generate(),
      sender: "configured-agent",
      run_id: "/root/研究者/child:2",
      incarnation: 1,
      catalog_revision: 1
    }

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "swarm:#{context.session_id}:target")
    on_exit(fn -> :ets.delete(@table, context.session_id) end)
    %{context: context}
  end

  test "three saved capabilities have distinct native identities and exact none permissions",
       ctx do
    assert Swarm.names() == @names
    assert {:ok, descriptors} = Swarm.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == @names

    for descriptor <- descriptors do
      assert descriptor.backend == Swarm
      assert descriptor.backend_context === ctx.context
      assert descriptor.tool_revision === 1
      assert descriptor.schema["additionalProperties"] == false
      assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
      assert Swarm.permission_level(descriptor.tool_name) == :none

      assert {:error, %Error{}} =
               InputSchema.validate(descriptor.schema, %{"session_id" => ctx.context.session_id})
    end

    assert {:ok, %{accepted: @names}} =
             ToolCatalog.admit_batch(descriptors, authority: authority(ctx))

    assert {:error, %Error{}} =
             ToolCatalog.admit_batch(descriptors, authority: %{authority(ctx) | grants: ["*"]})
  end

  test "classification uses persisted session and recipient or saved metadata, never run identity",
       ctx do
    for {name, args, action, suffix} <- [
          {@message, %{"to" => "target", "content" => "hello"}, "swarm.message",
           "messages:target"},
          {@teammate, %{"action" => "list"}, "swarm.teammate.list", "teammates"},
          {@teammate, %{"action" => "get", "name" => "saved"}, "swarm.teammate.get",
           "teammates:saved"},
          {@delete, %{}, "swarm.team.delete", "teammates"}
        ] do
      assert {:ok, %{action: ^action, resource: resource}} =
               Swarm.classify(ctx.context, operation(ctx, name, args))

      assert resource == "session:#{ctx.context.session_id}:swarm:#{suffix}"
      refute resource =~ ctx.context.run_id
    end
  end

  test "metadata and notification results are honest portable domain outcomes", ctx do
    assert {:ok, %{structured: created} = result} =
             Swarm.execute(operation(ctx, @teammate, %{"action" => "create", "name" => "saved"}))

    assert created.status == "configured"
    assert {:ok, _} = ResultProjection.to_part("created", result, tool_name: @teammate)

    assert {:ok, %{structured: %{status: "published", message_id: message_id}, content: text}} =
             Swarm.execute(operation(ctx, @message, %{"to" => "target", "content" => "hello"}))

    assert text =~ "notification"
    refute text =~ "delivered"

    assert_receive {:swarm_message,
                    %{id: ^message_id, from: "configured-agent", content: "hello"}}

    assert {:ok, %{structured: %{count: 1}, content: deleted}} =
             Swarm.execute(operation(ctx, @delete, %{}))

    assert deleted =~ "metadata"
    refute deleted =~ "terminated"
    refute deleted =~ "killed"
  end

  @tag :model_visible_result
  test "all teammate actions expose generated identities and complete saved metadata", ctx do
    assert {:ok, %{structured: created} = result} =
             Swarm.execute(operation(ctx, @teammate, %{"action" => "create"}))

    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(created))
    assert Ecto.UUID.cast(created.id) == {:ok, created.id}
    assert String.starts_with?(created.name, "teammate_")

    args = %{
      "action" => "update",
      "name" => created.name,
      "prompt" => "Review the stored design",
      "tools" => ["file_read"],
      "model" => "review-model"
    }

    assert {:ok, %{structured: updated} = result} = Swarm.execute(operation(ctx, @teammate, args))
    assert updated.id == created.id
    assert updated.prompt == args["prompt"]
    assert updated.tools == args["tools"]
    assert updated.model == args["model"]
    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(updated))

    for args <- [
          %{"action" => "get", "name" => created.name},
          %{"action" => "list"}
        ] do
      assert {:ok, result} = Swarm.execute(operation(ctx, @teammate, args))
      assert result.structured in [updated, [updated]]
      assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    end
  end

  @tag :model_visible_result
  test "large accepted teammate lists retain every field within the native wrapper budget", ctx do
    for n <- 1..7 do
      assert {:ok, _} =
               Swarm.execute(
                 operation(ctx, @teammate, %{
                   "action" => "create",
                   "name" => "reviewer-#{n}",
                   "prompt" => String.duplicate("x", 8192)
                 })
               )
    end

    assert {:ok, result} = Swarm.execute(operation(ctx, @teammate, %{"action" => "list"}))
    assert length(result.structured) == 7
    assert Enum.all?(result.structured, &(byte_size(&1.prompt) == 8192))
    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    assert {:ok, _} = Backplane.AgentRuntime.ToolEffects.validate_output(%{payload: result})
  end

  test "invalid input and model authority fail without metadata or notification", ctx do
    for {name, args} <- [
          {@message, %{"to" => "target", "content" => "hello", "sender" => "foreign"}},
          {@message,
           %{"to" => "target", "content" => "hello", "session_id" => Ecto.UUID.generate()}},
          {@message, %{"to" => "target", "content" => String.duplicate("x", 32769)}},
          {@teammate, %{"action" => "create", "name" => "saved", "tools" => [123]}},
          {@teammate, %{"action" => "get"}},
          {@delete, %{"session_id" => ctx.context.session_id}}
        ] do
      assert {:error, %Error{class: :validation}} = Swarm.execute(operation(ctx, name, args))
    end

    assert :ets.lookup(@table, ctx.context.session_id) == []
    refute_receive {:swarm_message, _}
  end

  test "construction and publication preserve exact trusted context while effects accept native enrichment",
       ctx do
    op = operation(ctx, @teammate, %{"action" => "create", "name" => "saved"})

    for context <- [
          nil,
          Map.delete(ctx.context, :sender),
          Map.put(ctx.context, :root, "/"),
          %{ctx.context | session_id: ctx.context.run_id},
          %{ctx.context | sender: " "},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0}
        ] do
      assert {:error, %Error{class: :validation}} = Swarm.descriptors(context)
    end

    for {field, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 1.0
        ] do
      changed = Map.put(op, field, value)
      assert {:error, :scope_mismatch} = Swarm.classify(ctx.context, changed)
      assert {:error, %Error{class: :forbidden}} = Swarm.execute(changed)
    end

    foreign = put_in(op, [:backend_context, :sender], "foreign")
    assert {:error, :scope_mismatch} = Swarm.classify(ctx.context, foreign)
    enriched = Map.put(ctx.context, :resource_owner_pid, self())

    assert {:error, :invalid_context} =
             Swarm.classify(enriched, %{op | backend_context: enriched})

    assert {:ok, _} = Swarm.execute(%{op | backend_context: enriched})
    bad = Map.put(enriched, :dispatch, fn -> :forbidden end)
    assert {:error, %Error{class: :validation}} = Swarm.execute(%{op | backend_context: bad})
    assert :ok = Swarm.cancel(op)
  end

  test "native Execution enforces grants revisions and schema before intent or effects", ctx do
    {:ok, descriptors} = Swarm.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))
    {:ok, budget} = Budget.new(%{work: 2})

    input =
      operation(ctx, @teammate, %{"action" => "create", "name" => "native"})
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

    options = [
      registry: bundle.registry,
      authority: authority(ctx),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    for {changed, opts} <- [
          {input, Keyword.put(options, :authority, %{authority(ctx) | grants: []})},
          {%{input | tool_revision: 2}, options},
          {%{input | arguments: Map.put(input.arguments, "session_id", Ecto.UUID.generate())},
           options}
        ] do
      {:ok, table} = EphemeralStore.new(1)

      assert {:error, %Error{}} =
               Execution.run(
                 EphemeralStore,
                 table,
                 record,
                 %{command: {:tool_invoked, 11, changed}},
                 opts
               )

      assert :ets.tab2list(table) == []
      assert :ets.lookup(@table, ctx.context.session_id) == []
    end

    {:ok, table} = EphemeralStore.new(1)

    assert {:ok, _, %{effects: [%{structured: %{name: "native", status: "configured"}}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )
  end

  test "native Conversation uses published descriptors without inheriting child lifecycle tools",
       ctx do
    {:ok, descriptors} = Swarm.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))

    calls = [
      {@teammate, %{"action" => "create", "name" => "conversation"}},
      {@message, %{"to" => "target", "content" => "notify only"}},
      {@delete, %{}}
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
        work: 10
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)

    assert {:ok, _} =
             Proof.prompt(caller, pid, "Save teammate metadata and publish a notification")

    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000

    assert [created, message, deleted] =
             Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))

    assert created.result.structured.status == "configured"
    assert message.result.structured.status == "published"
    assert deleted.result.structured.count == 1
    assert_receive {:swarm_message, %{from: "configured-agent", content: "notify only"}}
    assert :ets.lookup(@table, ctx.context.session_id) == []
  end

  defp authority(ctx),
    do: %{
      caller: "swarm-test",
      run_id: ctx.context.run_id,
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

  defp operation(ctx, name, args),
    do: %{
      tool_name: name,
      tool_revision: 1,
      arguments: args,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context
    }
end
