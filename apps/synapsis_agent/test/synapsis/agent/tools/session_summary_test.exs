defmodule Synapsis.Agent.Tools.SessionSummaryTest do
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
  alias Synapsis.Agent.Tools.SessionSummary
  alias Synapsis.Session.Store

  @name "synapsis::session_summarize"

  defmodule RecordingBackend do
    def execute(operation) do
      send(operation.backend_context.test_pid, :summary_dispatched)
      {:ok, %{content: "Candidates only", structured: %{candidates: []}}}
    end
  end

  defmodule SnapshotOwner do
    use GenServer
    def start_link(status), do: GenServer.start_link(__MODULE__, status)
    @impl true
    def init(status), do: {:ok, status}
    @impl true
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

  setup do
    assert Code.ensure_loaded?(SessionSummary), "native session summary is not implemented"
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, provider: "unavailable-summary-provider"})
    on_exit(fn -> Store.delete_session(id) end)

    %{
      context: %{
        session_id: id,
        run_id: "/root/researcher:1",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "revision one descriptor has closed bounded inputs and read permission", ctx do
    assert SessionSummary.names() == [@name]
    assert SessionSummary.permission_level(@name) == :read
    assert {:ok, [descriptor]} = SessionSummary.descriptors(ctx.context)
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision === 1
    assert descriptor.backend == SessionSummary
    assert descriptor.backend_context === ctx.context
    assert descriptor.schema["additionalProperties"] == false

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(focus kinds message_range scope use_llm)

    assert descriptor.schema["properties"]["focus"]["maxLength"] == 512
    assert descriptor.schema["properties"]["use_llm"]["default"] == true
    assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}

    assert {:ok, _} =
             ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    for selector <- ~w(session_id path provider model run_id) do
      assert {:error, %Error{}} = InputSchema.validate(descriptor.schema, %{selector => "other"})
    end
  end

  test "classification binds persisted session separately from opaque native run and rejects scope drift",
       ctx do
    op = operation(ctx, %{"use_llm" => false})

    assert {:ok, %{action: "session.summarize", resource: resource}} =
             SessionSummary.classify(ctx.context, op)

    assert resource == "session:#{ctx.context.session_id}:summary"

    for {key, value} <- [run_id: "other", incarnation: 1.0, catalog_revision: 2, tool_revision: 2] do
      assert {:error, :scope_mismatch} =
               SessionSummary.classify(ctx.context, Map.put(op, key, value))

      assert {:error, %Error{class: :forbidden}} = SessionSummary.execute(Map.put(op, key, value))
    end

    for context <- [
          Map.put(ctx.context, :provider, "other"),
          %{ctx.context | session_id: "bad"},
          %{ctx.context | run_id: ""}
        ] do
      assert {:error, %Error{class: :validation}} = SessionSummary.descriptors(context)
    end

    assert {:error, %Error{class: :validation}} =
             SessionSummary.execute(%{op | backend_context: Map.put(ctx.context, :store, Store)})
  end

  @tag :model_visible_result
  test "native durable fallback returns reviewed candidates without persisting memories", ctx do
    text = String.duplicate("A durable architecture decision with explicit ownership. ", 3)

    :ok =
      Store.commit_turns(
        ctx.context.session_id,
        0,
        [%{id: Ecto.UUID.generate(), role: "user", parts: [%{type: "text", text: text}]}],
        %{id: ctx.context.session_id}
      )

    before = Synapsis.Memory.list_semantic()

    assert {:ok, %{content: content, structured: result}} =
             SessionSummary.execute(
               operation(ctx, %{"use_llm" => false, "focus" => "architecture"})
             )

    assert "Generated 1 memory candidate(s) for review; candidates were not saved.\n" <> json =
             content

    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(result))
    assert byte_size(Jason.encode!(%{content: content, structured: result})) <= 65_536
    assert result.source == "durable_session"
    assert [%{summary: ^text}] = result.candidates
    assert Synapsis.Memory.list_semantic() == before
    assert length(Synapsis.Message.list_by_session(ctx.context.session_id)) == 1
    assert :ok = SessionSummary.cancel(operation(ctx, %{}))

    for args <- [
          %{"provider" => "other"},
          %{"scope" => "range"},
          %{"focus" => String.duplicate("a", 513)},
          %{"use_llm" => "false"}
        ] do
      assert {:error, %Error{class: :validation}} = SessionSummary.execute(operation(ctx, args))
    end
  end

  @tag :model_visible_result
  test "empty summaries expose their source and no-messages explanation", ctx do
    assert {:ok, result} = SessionSummary.execute(operation(ctx, %{"use_llm" => false}))
    assert result.structured.candidates == []
    assert result.structured.message == "No messages to summarize"
    assert result.structured.source == "durable_session"

    assert "Generated 0 memory candidate(s) for review; candidates were not saved.\n" <> json =
             result.content

    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(result.structured))
  end

  test "native admission rejects grants revisions and invalid selectors before intent or dispatch",
       ctx do
    {:ok, [descriptor]} = SessionSummary.descriptors(ctx.context)
    descriptor = %{descriptor | backend: RecordingBackend, backend_context: %{test_pid: self()}}
    {:ok, bundle} = ToolCatalog.admit_batch([descriptor], authority: authority(ctx))
    {:ok, budget} = Budget.new(%{work: 2})

    input =
      operation(ctx, %{"use_llm" => false})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "summary"})

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
      effect_timeout: 1000,
      cleanup_timeout: 500
    ]

    for {changed, options} <- [
          {input, Keyword.put(opts, :authority, %{authority(ctx) | grants: []})},
          {%{input | tool_revision: 2}, opts},
          {%{input | arguments: %{"session_id" => Ecto.UUID.generate()}}, opts}
        ] do
      {:ok, table} = EphemeralStore.new(1)

      assert {:error, %Error{}} =
               Execution.run(
                 EphemeralStore,
                 table,
                 record,
                 %{command: {:tool_invoked, 11, changed}},
                 options
               )

      assert :ets.tab2list(table) == []
      refute_receive :summary_dispatched
    end
  end

  test "Conversation includes the unpersisted current user turn through its trusted owner", ctx do
    {:ok, descriptors} = SessionSummary.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("Done")],
        else: [
          Proof.call(@name, %{"use_llm" => false, "focus" => "live architecture"}),
          Proof.completed("Reviewing")
        ]
    end

    opts =
      Proof.options(ctx.context.run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        work: 6
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)
    prompt = String.duplicate("Current live architecture marker and ownership decision. ", 3)
    assert {:ok, _} = Proof.prompt(caller, pid, prompt)
    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3000
    assert [message] = Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))
    refute Map.get(message.result, :is_error, false)
    assert message.result.structured.source == "live_session"

    assert Enum.any?(
             message.result.structured.candidates,
             &String.contains?(&1.summary, "Current live architecture marker")
           )

    assert Synapsis.Message.list_by_session(ctx.context.session_id) == []

    wrong = put_in(ctx.context.run_id, "/another/run")
    op = operation(wrong, %{"use_llm" => false})

    assert {:error, %Error{class: :forbidden}} =
             SessionSummary.execute(%{
               op
               | backend_context: Map.put(wrong.context, :resource_owner_pid, pid)
             })
  end

  test "live snapshot limits precede conversion and recent keeps only the newest ten", ctx do
    valid = %{role: :user, content: "Architecture context with an explicit ownership decision."}
    # Unsupported roles would fail conversion. Budget errors prove conversion
    # was never attempted for these oversized snapshots, without any provider.
    for {messages, code} <- [
          {[%{role: :unsupported, content: "invalid"} | List.duplicate(valid, 200)],
           "message_limit"},
          {[%{role: :unsupported, content: String.duplicate("x", 262_145)}], "transcript_limit"}
        ] do
      owner = snapshot_owner(ctx, messages)
      op = operation(ctx, %{"use_llm" => false})

      assert {:error, %Error{class: :budget_exceeded, details: %{code: ^code}}} =
               SessionSummary.execute(%{
                 op
                 | backend_context: Map.put(ctx.context, :resource_owner_pid, owner)
               })
    end

    messages = [
      %{role: :unsupported, content: "Old discarded content"}
      | Enum.map(1..220, fn n ->
          %{role: :user, content: "Live message #{n} architecture ownership decision."}
        end)
    ]

    owner = snapshot_owner(ctx, messages)
    op = operation(ctx, %{"scope" => "recent", "focus" => "architecture", "use_llm" => false})

    assert {:ok,
            %{structured: %{source: "live_session", message_count: 10, candidates: [first | _]}}} =
             SessionSummary.execute(%{
               op
               | backend_context: Map.put(ctx.context, :resource_owner_pid, owner)
             })

    assert String.starts_with?(first.summary, "Live message 220")
    refute first.summary =~ "Live message 210"
  end

  defp snapshot_owner(ctx, messages) do
    status = %{
      run: Map.take(ctx.context, [:run_id, :incarnation]),
      catalog_revision: ctx.context.catalog_revision,
      messages: messages
    }

    start_supervised!({SnapshotOwner, status}, id: make_ref())
  end

  defp authority(ctx),
    do: %{
      caller: "session-summary-test",
      run_id: ctx.context.run_id,
      grants: [@name],
      tool_revisions: %{@name => 1}
    }

  defp operation(ctx, args),
    do: %{
      tool_name: @name,
      tool_revision: 1,
      arguments: args,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context
    }
end
