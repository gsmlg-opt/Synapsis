defmodule Synapsis.Agent.Tools.AgentCommunicationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog,
    ToolEffects
  }

  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.{AgentCommunication, Policy, ResultProjection}
  alias Synapsis.AgentCommunication, as: Domain
  alias Synapsis.{AgentMessages, Session.Store}

  @send "synapsis::agent_send"
  @ask "synapsis::agent_ask"
  @reply "synapsis::agent_reply"
  @inbox "synapsis::agent_inbox"
  @names [@send, @ask, @reply, @inbox]

  defmodule DeadlineSender do
    @behaviour Phoenix.PubSub.Sender
    @impl true
    def send(pid, hold_ms, message, state) do
      Kernel.send(pid, message)
      wait_until(System.monotonic_time(:millisecond) + hold_ms)
      state
    end

    defp wait_until(deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        receive do
        after
          remaining -> wait_until(deadline)
        end
      end
    end
  end

  setup do
    assert Code.ensure_loaded?(AgentCommunication),
           "native persistent mailbox tools are not implemented"

    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    mailbox = "configured Agent #{id}"
    recipient = "review mailbox:#{id}"
    :ok = Store.put_meta(id, %{id: id, agent: mailbox})
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{recipient}")
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{mailbox}")
    on_exit(fn -> Store.delete_session(id) end)

    %{
      context: %{
        session_id: id,
        agent_id: mailbox,
        primary: true,
        run_id: "/root/研究者:1",
        incarnation: 1,
        catalog_revision: 1
      },
      recipient: recipient
    }
  end

  test "four fixed revision-one descriptors preserve legacy fields and conservative safety",
       ctx do
    assert AgentCommunication.names() == @names
    assert {:ok, descriptors} = AgentCommunication.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == @names

    properties = [
      ~w(content metadata to type),
      ~w(context question timeout_ms to),
      ~w(content ref status),
      ~w(action limit ref since type)
    ]

    for {descriptor, keys} <- Enum.zip(descriptors, properties) do
      assert descriptor.backend == AgentCommunication
      assert descriptor.backend_context === ctx.context
      assert descriptor.tool_revision === 1
      assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
      assert AgentCommunication.permission_level(descriptor.tool_name) == :none
      assert descriptor.schema["additionalProperties"] == false
      assert Enum.sort(Map.keys(descriptor.schema["properties"])) == Enum.sort(keys)

      for selector <- ~w(agent_id session_id primary run_id backend kv deadline) do
        assert {:error, %Error{}} =
                 InputSchema.validate(descriptor.schema, %{selector => "forged"})
      end
    end

    assert Enum.at(descriptors, 0).schema["properties"]["content"]["maxLength"] == 16_384
    assert Enum.at(descriptors, 1).schema["properties"]["timeout_ms"]["maximum"] == 300_000
    assert Enum.at(descriptors, 3).schema["properties"]["limit"]["maximum"] == 100

    assert {:ok, _} =
             ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
  end

  test "pure classification binds configured mailbox and session, never opaque runtime identity",
       ctx do
    for {name, args, action, extra} <- [
          {@send, %{"to" => ctx.recipient, "content" => "hello"}, "agent.mail.send",
           %{"to" => ctx.recipient}},
          {@ask, %{"to" => ctx.recipient, "question" => "question"}, "agent.mail.ask",
           %{"to" => ctx.recipient}},
          {@reply, %{"ref" => "opaque correlation", "content" => "answer"}, "agent.mail.reply",
           %{"ref" => "opaque correlation"}},
          {@inbox, %{"action" => "unread"}, "agent.mail.inbox.unread", %{}},
          {@inbox, %{"action" => "thread", "ref" => "thread correlation"},
           "agent.mail.inbox.thread", %{"ref" => "thread correlation"}}
        ] do
      assert {:ok, %{action: ^action, resource: "agent_mail:" <> json}} =
               AgentCommunication.classify(ctx.context, operation(ctx, name, args))

      assert Jason.decode!(json) ==
               Map.merge(
                 %{"mailbox" => ctx.context.agent_id, "session_id" => ctx.context.session_id},
                 extra
               )

      refute json =~ ctx.context.run_id
    end

    child = put_in(ctx.context.primary, false)

    assert {:error, :primary_only} =
             AgentCommunication.classify(
               child.context,
               operation(child, @ask, %{"to" => ctx.recipient, "question" => "question"})
             )
  end

  test "exact scope, trusted context and schema fences produce invocation-bound non-dispatch",
       ctx do
    op = operation(ctx, @send, %{"to" => ctx.recipient, "content" => "hello"})

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 2,
          tool_revision: 1.0
        ] do
      bad = Map.put(op, key, value)
      assert {:error, :scope_mismatch} = AgentCommunication.classify(ctx.context, bad)

      if key in [:incarnation, :tool_revision] do
        # Native rejection requires integer identity fields; malformed identity
        # cannot be upgraded into a valid invocation-bound non-dispatch proof.
        assert {:error, %Error{class: :unknown_outcome}} = AgentCommunication.execute(bad)
      else
        assert {:rejected, proof} = AgentCommunication.execute(bad)

        assert {:ok, %{error: %Error{class: :forbidden}}} =
                 ToolEffects.validate_rejection(proof, bad)

        assert {:error, %Error{class: :unknown_outcome}} =
                 ToolEffects.validate_rejection(proof, %{bad | arguments: %{}})
      end
    end

    for context <- [
          Map.put(ctx.context, :kv, Concord.Turso),
          %{ctx.context | agent_id: ""},
          %{ctx.context | primary: nil},
          %{ctx.context | session_id: "opaque run"},
          %{ctx.context | run_id: "bad\0run"}
        ] do
      assert {:error, %Error{class: :validation}} = AgentCommunication.descriptors(context)
    end

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> flunk("unexpected interaction") end,
        resource_owner_pid: self(),
        emit: fn _ -> :unused end,
        goal: nil,
        goal_binding: nil
      })

    assert {:ok, %{structured: %{count: 0}}} =
             AgentCommunication.execute(%{
               operation(ctx, @inbox, %{"action" => "history"})
               | backend_context: enriched
             })

    bad = %{op | backend_context: Map.put(enriched, :deadline, 0)}
    assert {:rejected, proof} = AgentCommunication.execute(bad)
    assert {:ok, _} = ToolEffects.validate_rejection(proof, bad)

    for args <- [
          Map.put(op.arguments, "from", "forged"),
          %{op.arguments | "content" => String.duplicate("x", 16_385)},
          %{"to" => ctx.recipient, "content" => "ok", "metadata" => %{"token" => self()}}
        ] do
      bad = %{op | arguments: args}
      assert {:rejected, proof} = AgentCommunication.execute(bad)

      assert {:ok, %{error: %Error{class: :validation}}} =
               ToolEffects.validate_rejection(proof, bad)
    end

    refute_receive {:agent_envelope, _}, 10
    assert :ok = AgentCommunication.cancel(op)
  end

  test "missing persisted session rejects before mail persistence", ctx do
    missing = put_in(ctx.context.session_id, Ecto.UUID.generate())
    op = operation(missing, @send, %{"to" => ctx.recipient, "content" => "hello"})
    assert {:rejected, proof} = AgentCommunication.execute(op)
    assert {:ok, %{error: %Error{class: :not_found}}} = ToolEffects.validate_rejection(proof, op)
    refute_receive {:agent_envelope, _}, 10
  end

  @tag :model_visible_result
  test "native Execution sends durable mail then replies atomically and filters marking inbox",
       ctx do
    assert {:ok, _, %{effects: [%{structured: sent} = result]}} =
             native(ctx, @send, %{"to" => ctx.recipient, "content" => "hello", "type" => "info"})

    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(sent))
    assert sent.status == "persisted"
    assert sent.publication == "published"
    assert {:ok, _} = ResultProjection.to_part("send", {:ok, result}, tool_name: @send)
    assert_receive {:agent_envelope, %{type: :notification}}
    assert {:ok, message} = AgentMessages.fetch(sent.message_id)
    assert message.from_agent_id == ctx.context.agent_id
    assert message.session_id == ctx.context.session_id
    assert message.payload["level"] == "info"
    request = incoming_request!(ctx)

    assert {:ok, _, %{effects: [%{structured: replied} = reply_result]}} =
             native(ctx, @reply, %{"ref" => request.ref, "content" => "answer"})

    assert Jason.decode!(reply_result.content) == Jason.decode!(Jason.encode!(replied))
    assert {:ok, %{status: "acknowledged"}} = AgentMessages.fetch(request.id)
    assert {:ok, response} = AgentMessages.fetch(replied.message_id)
    assert response.in_reply_to == request.id

    assert {:ok, _, %{effects: [%{structured: inbox} = inbox_result]}} =
             native(ctx, @inbox, %{
               "action" => "thread",
               "ref" => request.ref,
               "type" => "response"
             })

    assert Jason.decode!(inbox_result.content) == Jason.decode!(Jason.encode!(inbox))
    assert Enum.map(inbox.messages, & &1.id) == [response.id]

    assert {:ok, _, %{effects: [%{structured: %{count: 0}} = empty_result]}} =
             native(ctx, @inbox, %{
               "action" => "history",
               "since" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60, :second))
             })

    assert Jason.decode!(empty_result.content) ==
             Jason.decode!(Jason.encode!(empty_result.structured))

    {:ok, delivered} =
      AgentMessages.create(%{
        ref: Ecto.UUID.generate(),
        from_agent_id: ctx.recipient,
        to_agent_id: ctx.context.agent_id,
        type: "notification",
        session_id: ctx.context.session_id,
        payload: %{"content" => "notice"}
      })

    assert {:ok, _, %{effects: [%{structured: unread} = unread_result]}} =
             native(ctx, @inbox, %{"action" => "unread", "type" => "notification"})

    assert Jason.decode!(unread_result.content) == Jason.decode!(Jason.encode!(unread))
    assert [%{id: id, status: "read"}] = unread.messages
    assert id == delivered.id
  end

  @tag :model_visible_result
  test "native Execution ask receives persisted counterpart response and owner cancellation expires request",
       ctx do
    task =
      Task.async(fn ->
        native(
          ctx,
          @ask,
          %{"to" => ctx.recipient, "question" => "question", "timeout_ms" => 2_000},
          effect_timeout: 3_000
        )
      end)

    assert_receive {:agent_envelope, %{type: :request, ref: ref}}, 1_000

    assert {:ok, _} =
             Domain.reply(%{"ref" => ref, "content" => "answer"}, %{
               agent_id: ctx.recipient,
               session_id: ctx.context.session_id,
               primary: false
             })

    assert {:ok, _,
            %{
              effects: [
                %{structured: %{status: "received", response: %{"content" => "answer"}}} = result
              ]
            }} =
             Task.await(task, 3_000)

    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))

    caller =
      spawn(fn ->
        AgentCommunication.execute(
          operation(ctx, @ask, %{
            "to" => ctx.recipient,
            "question" => "cancel me",
            "timeout_ms" => 2_000
          })
        )
      end)

    assert_receive {:agent_envelope, %{type: :request, ref: cancelled}}, 1_000
    Process.exit(caller, :kill)

    eventually(fn ->
      match?({:ok, %{status: "expired"}}, AgentMessages.fetch_by_ref(cancelled))
    end)
  end

  @tag :model_visible_result
  test "known preeffect domain errors reject while timeout after persistence settles with receipt",
       ctx do
    request = incoming_request!(ctx)
    assert {:ok, _} = AgentMessages.expire_request(request.id)
    op = operation(ctx, @reply, %{"ref" => request.ref, "content" => "late"})
    assert {:rejected, proof} = AgentCommunication.execute(op)

    assert {:ok, %{error: %Error{class: :resource_conflict}}} =
             ToolEffects.validate_rejection(proof, op)

    request = incoming_request!(ctx)

    assert {:ok, _} =
             AgentCommunication.execute(
               operation(ctx, @reply, %{"ref" => request.ref, "content" => "first"})
             )

    assert {:rejected, proof} =
             AgentCommunication.execute(
               operation(ctx, @reply, %{"ref" => request.ref, "content" => "duplicate"})
             )

    assert proof.error.class == :resource_conflict

    assert {:ok, _, %{effects: [result]}} =
             native(ctx, @ask, %{
               "to" => ctx.recipient,
               "question" => "timeout",
               "timeout_ms" => 40
             })

    assert result.is_error
    assert "Agent mailbox operation completed with an error.\n" <> json = result.content
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(result.structured))
    assert result.structured.code == "timeout"
    assert result.structured.effect == "completed"
    assert result.structured.request_status == "expired"
    assert result.error.class == :timeout
    assert ToolEffects.settlement({:ok, result}, %{read_only: false}) == :settled
  end

  test "uncertain writes retain native unknown outcome and redact storage diagnostics", ctx do
    prior = Application.get_env(:concord, :kv)
    Application.put_env(:concord, :kv, Keyword.put(prior || [], :max_value_bytes, 1))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:concord, :kv, prior),
        else: Application.delete_env(:concord, :kv)
    end)

    assert {:error, %Error{class: :unknown_outcome} = error} =
             native(ctx, @send, %{"to" => ctx.recipient, "content" => "hello"})

    assert error.details.code == "storage_failed"
    assert error.details.receipt.effect == "uncertain"
    refute inspect(error) =~ "max_value_bytes"
    refute_receive {:agent_envelope, _}, 10
    assert ToolEffects.settlement({:error, error}, %{read_only: false}) == :uncertain
  end

  @tag timeout: 10_000
  @tag :model_visible_result
  test "partial reply publication receipt stays visible and settled after fixed domain deadline",
       ctx do
    request = incoming_request!(ctx)

    :ok =
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent_reply:#{request.ref}",
        sender: {DeadlineSender, 5_050}
      )

    task =
      Task.async(fn ->
        native(ctx, @reply, %{"ref" => request.ref, "content" => "answer"}, effect_timeout: 7_000)
      end)

    assert_receive {:agent_reply, ref, %{"content" => "answer"}}, 1_000
    assert ref == request.ref
    assert {:ok, _, %{effects: [result]}} = Task.await(task, 8_000)
    assert result.is_error
    assert "Agent mailbox operation completed with an error.\n" <> json = result.content
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(result.structured))
    assert result.error.class == :timeout
    assert result.structured.publication == "partial"
    assert result.structured.reply_publication == "published"
    assert result.structured.mailbox_publication == "not_published"
    assert {:ok, %{status: "acknowledged"}} = AgentMessages.fetch(request.id)
    assert {:ok, _} = AgentMessages.fetch(result.structured.message_id)
    assert {:ok, _} = ResultProjection.to_part("partial", {:ok, result}, tool_name: @reply)
    refute_receive {:agent_envelope, %{type: :response}}, 10
  end

  test "exact grants revisions and schema errors are denied before Execution intent", ctx do
    {:ok, descriptors} = AgentCommunication.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))

    input =
      Map.drop(operation(ctx, @send, %{"to" => ctx.recipient, "content" => "hello"}), [
        :backend_context
      ])

    for {changed, changed_authority} <- [
          {input, %{bundle.authority | grants: []}},
          {%{input | tool_revision: 2}, bundle.authority},
          {%{input | arguments: Map.put(input.arguments, "agent_id", "forged")}, bundle.authority}
        ] do
      {:ok, table} = EphemeralStore.new(1)
      {:ok, budget} = Budget.new(%{work: 2})

      assert {:error, %Error{}} =
               Execution.run(
                 EphemeralStore,
                 table,
                 record(ctx),
                 %{command: {:tool_invoked, 11, changed}},
                 registry: bundle.registry,
                 authority: changed_authority,
                 budget: budget,
                 effect_timeout: 1_000,
                 commit_timeout: 500,
                 cleanup_timeout: 500
               )

      assert :ets.tab2list(table) == []
    end

    refute_receive {:agent_envelope, _}, 10
  end

  test "host Policy rejects child ask before Conversation tool intent", ctx do
    child = put_in(ctx.context.primary, false)
    {:ok, descriptors} = AgentCommunication.descriptors(child.context)

    {:ok, bundle} =
      ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(child))

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("Done")],
        else: [
          Proof.call(@ask, %{"to" => ctx.recipient, "question" => "forbidden"}),
          Proof.completed("Working")
        ]
    end

    scope =
      Map.take(child.context, [:run_id, :incarnation, :catalog_revision])
      |> Map.put(:caller, "mail-test")

    tools =
      Map.new(@names, fn name ->
        {name,
         %{
           tool_revision: 1,
           classify: fn invocation ->
             AgentCommunication.classify(
               child.context,
               Map.put(invocation, :backend_context, child.context)
             )
           end
         }}
      end)

    context = %{
      tool_scope: scope,
      tool_policy: %{scope: scope, tools: tools, decisions: %{}},
      tool_readiness: %{
        scope: scope,
        tools: Map.new(@names, &{&1, %{tool_revision: 1, status: :ready}})
      },
      script: script
    }

    opts =
      Proof.options(child.context.run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        hooks: Policy,
        provider_context: context,
        work: 5
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Try ask")
    run_id = child.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
    {:ok, persisted} = EphemeralStore.load(opts[:context], run_id)
    assert Enum.filter(Map.values(persisted.run.execution_intents), &(&1.type == :tool)) == []

    assert [%{result: %{is_error: true}}] =
             Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))

    refute_receive {:agent_envelope, _}, 10
  end

  test "Conversation executes all four persistent mailbox tools with runtime enrichment", ctx do
    request = incoming_request!(ctx)
    {:ok, descriptors} = AgentCommunication.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))

    calls = [
      {@send, %{"to" => ctx.recipient, "content" => "notice"}},
      {@ask, %{"to" => ctx.recipient, "question" => "question", "timeout_ms" => 2_000}},
      {@reply, %{"ref" => request.ref, "content" => "answer incoming"}},
      {@inbox, %{"action" => "history", "limit" => 20}}
    ]

    script = fn request ->
      index = Enum.count(request.messages, &(&1.role == :tool))

      case Enum.at(calls, index) do
        {name, args} ->
          [
            put_in(Proof.call(name, args), [:tool_call, :id], "mail-#{index}"),
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
        work: 12,
        effect_timeout: 3_000
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)

    prompt =
      Task.Supervisor.async_nolink(caller, fn ->
        Conversation.prompt(pid, "Exchange persistent mail")
      end)

    assert_receive {:agent_envelope, %{type: :notification}}, 1_000
    assert_receive {:agent_envelope, %{type: :request, ref: ref}}, 1_000

    assert {:ok, _} =
             Domain.reply(%{"ref" => ref, "content" => "counterpart answer"}, %{
               agent_id: ctx.recipient,
               session_id: ctx.context.session_id,
               primary: false
             })

    assert {:ok, _} = Task.await(prompt, 3_000)
    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000

    assert [sent, asked, replied, inbox] =
             Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))

    for message <- [sent, asked, replied, inbox],
        do: refute(Map.get(message.result, :is_error, false))

    assert asked.result.structured.response["content"] == "counterpart answer"
    assert sent.result.structured.to == ctx.recipient
    assert replied.result.structured.in_reply_to == request.ref
    assert inbox.result.structured.count >= 4
    {:ok, persisted} = EphemeralStore.load(opts[:context], run_id)
    assert Enum.count(Map.values(persisted.run.execution_intents), &(&1.type == :tool)) == 4
  end

  defp incoming_request!(ctx) do
    {:ok, request} =
      AgentMessages.create(%{
        ref: Ecto.UUID.generate(),
        from_agent_id: ctx.recipient,
        to_agent_id: ctx.context.agent_id,
        type: "request",
        session_id: ctx.context.session_id,
        payload: %{"question" => "incoming"},
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    request
  end

  defp native(ctx, name, args, overrides \\ []) do
    {:ok, descriptors} = AgentCommunication.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})
    input = Map.drop(operation(ctx, name, args), [:backend_context])

    opts =
      Keyword.merge(
        [
          registry: bundle.registry,
          authority: bundle.authority,
          budget: budget,
          commit_timeout: 500,
          effect_timeout: 2_000,
          cleanup_timeout: 500
        ],
        overrides
      )

    Execution.run(
      EphemeralStore,
      table,
      record(ctx),
      %{command: {:tool_invoked, 11, input}},
      opts
    )
  end

  defp record(ctx),
    do: %{
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

  defp authority(ctx),
    do: %{
      caller: "mail-test",
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
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: Ecto.UUID.generate()
    }

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          receive do
          after
            10 -> eventually(fun, attempts - 1)
          end
      )
end
