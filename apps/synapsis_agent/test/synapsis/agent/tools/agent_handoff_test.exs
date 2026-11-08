defmodule Synapsis.Agent.Tools.AgentHandoffTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog,
    ToolEffects
  }

  alias Synapsis.Agent.Tools.{AgentHandoff, ResultProjection}
  alias Synapsis.{AgentMessages, Session.Store}

  @moduletag :tmp_dir
  @name "synapsis::agent_handoff"

  setup %{tmp_dir: root} do
    assert Code.ensure_loaded?(AgentHandoff), "the native handoff adapter is not implemented"
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    to = "native-handoff-#{Ecto.UUID.generate()}"
    :ok = Store.put_meta(id, %{id: id, agent: "configured-agent"})
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{to}")

    on_exit(fn ->
      Store.delete_session(id)

      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{
      root: root,
      context: %{
        agent_id: "configured-agent",
        session_id: id,
        primary: false,
        run_id: "/root/研究者/child:2",
        incarnation: 1,
        catalog_revision: 1
      },
      input: %{"to" => to, "summary" => "Findings", "instructions" => "Review them"}
    }
  end

  test "one conservative native capability retains fields and exact authority", ctx do
    assert AgentHandoff.names() == [@name]
    assert AgentHandoff.permission_level(@name) == :none
    assert {:ok, [descriptor]} = AgentHandoff.descriptors(ctx.context)
    assert descriptor.backend == AgentHandoff
    assert descriptor.backend_context === ctx.context
    assert descriptor.tool_revision === 1
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert descriptor.schema["additionalProperties"] == false

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(artifacts constraints instructions priority summary to)

    assert {:ok, _} = InputSchema.validate(descriptor.schema, ctx.input)

    assert {:ok, _} =
             ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    assert {:error, %Error{}} =
             ToolCatalog.admit_batch([descriptor],
               mode: :strict,
               authority: %{authority(ctx) | grants: ["*"]}
             )
  end

  test "classification binds configured sender session and recipient rather than native run",
       ctx do
    assert {:ok, %{action: "agent.mail.handoff", resource: resource}} =
             AgentHandoff.classify(ctx.context, operation(ctx))

    assert resource =~ ctx.context.agent_id
    assert resource =~ ctx.context.session_id
    assert resource =~ ctx.input["to"]
    refute resource =~ ctx.context.run_id

    for {key, value} <- [
          run_id: "foreign",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 2
        ] do
      assert {:error, _} = AgentHandoff.classify(ctx.context, Map.put(operation(ctx), key, value))
    end
  end

  @tag :model_visible_result
  test "native execution returns durable portable receipts without claiming delegation", ctx do
    assert {:ok, _, %{effects: [result]}} = native(ctx)
    receipt = result.structured

    assert "Handoff mail and Workspace artifact persisted; notifications published.\n" <> json =
             result.content

    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(receipt))
    refute result.content =~ ctx.root
    refute result.content =~ ctx.context.run_id
    assert receipt.status == "persisted"
    assert receipt.artifact_status == "persisted"
    assert receipt.mailbox_publication == "published"
    assert receipt.artifact_path == "/agents/configured-agent/handoffs/#{receipt.ref}.json"
    assert {:ok, message} = AgentMessages.fetch(receipt.message_id)
    assert message.from_agent_id == ctx.context.agent_id
    assert message.session_id == ctx.context.session_id
    assert message.type == "handoff"
    assert_receive {:agent_envelope, %{type: :handoff, ref: ref}}
    assert ref == receipt.ref
    assert {:ok, part} = ResultProjection.to_part("handoff", {:ok, result}, tool_name: @name)
    assert part.projection["result"]["structured"]["artifact_path"] == receipt.artifact_path
    refute String.downcase(result.content) =~ "delegated"
    refute String.downcase(result.content) =~ "started"
  end

  test "only exact trusted descriptor context is accepted with native execution enrichment",
       ctx do
    for context <- [
          Map.delete(ctx.context, :agent_id),
          Map.put(ctx.context, :path, "/agents/other/handoffs/a.json"),
          %{ctx.context | session_id: ctx.context.run_id},
          %{ctx.context | incarnation: 1.0},
          %{ctx.context | agent_id: "../other"}
        ] do
      assert {:error, %Error{}} = AgentHandoff.descriptors(context)
    end

    op = operation(ctx)
    enriched = Map.put(ctx.context, :resource_owner_pid, self())
    assert {:error, _} = AgentHandoff.classify(enriched, %{op | backend_context: enriched})
    assert {:ok, _} = AgentHandoff.execute(%{op | backend_context: enriched})

    forged = Map.put(enriched, :artifact_writer, fn -> :forged end)
    assert {:rejected, proof} = AgentHandoff.execute(%{op | backend_context: forged})

    assert {:ok, %{error: %Error{class: :validation}}} =
             ToolEffects.validate_rejection(
               proof,
               %{op | backend_context: forged}
             )

    assert :ok = AgentHandoff.cancel(op)
  end

  test "grant revision and schema failures never commit native intent or handoff effects", ctx do
    {:ok, descriptors} = AgentHandoff.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
    input = Map.drop(operation(ctx), [:backend_context])

    for {changed, changed_authority} <- [
          {input, %{bundle.authority | grants: []}},
          {%{input | tool_revision: 2}, bundle.authority},
          {%{
             input
             | arguments: Map.put(input.arguments, "path", "/agents/other/handoffs/a.json")
           }, bundle.authority}
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
                 effect_timeout: 2_000,
                 commit_timeout: 500,
                 cleanup_timeout: 500
               )

      assert :ets.tab2list(table) == []
    end

    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    refute_receive {:agent_envelope, _}, 0
  end

  test "missing persisted session rejects before either domain write", ctx do
    :ok = Store.delete_session(ctx.context.session_id)
    op = operation(ctx)
    assert {:rejected, proof} = AgentHandoff.execute(op)
    assert {:ok, %{error: %Error{class: :not_found}}} = ToolEffects.validate_rejection(proof, op)
    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    assert Path.wildcard(Path.join(ctx.root, "agents/**/*")) == []
  end

  @tag :model_visible_result
  test "confirmed partial writes settle errors while unconfirmed metadata stays unknown", ctx do
    directory = Path.join(ctx.root, "agents/configured-agent/handoffs")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o555)
    on_exit(fn -> File.chmod(directory, 0o755) end)
    assert {:ok, _, %{effects: [partial]}} = native(ctx)
    assert partial.is_error

    assert "Handoff completed partially; see persistence and publication receipts.\n" <> json =
             partial.content

    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(partial.structured))
    assert partial.error.details.receipt == partial.structured
    refute partial.content =~ ctx.root
    refute partial.content =~ ctx.context.run_id
    assert partial.structured.effect == "completed"
    assert partial.structured.message_status == "persisted"
    assert partial.structured.artifact_status == "failed"
    assert ToolEffects.settlement({:ok, partial}, %{read_only: false}) == :settled

    File.chmod!(directory, 0o755)
    metadata = Path.join(ctx.root, ".synapsis/meta")
    File.mkdir_p!(metadata)
    File.chmod!(metadata, 0o555)
    on_exit(fn -> File.chmod(metadata, 0o755) end)
    assert {:error, %Error{class: :unknown_outcome} = error} = native(ctx)
    assert error.details.receipt.message_status == "persisted"
    assert error.details.receipt.artifact_content_status == "persisted"
    assert error.details.receipt.artifact_metadata_status == "unconfirmed"
    assert ToolEffects.settlement({:error, error}, %{read_only: false}) == :uncertain
    refute_receive {:agent_envelope, _}, 0
  end

  defp native(ctx) do
    {:ok, descriptors} = AgentHandoff.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})
    input = Map.drop(operation(ctx), [:backend_context])

    Execution.run(EphemeralStore, table, record(ctx), %{command: {:tool_invoked, 11, input}},
      registry: bundle.registry,
      authority: bundle.authority,
      budget: budget,
      effect_timeout: 3_000,
      commit_timeout: 500,
      cleanup_timeout: 500
    )
  end

  defp authority(ctx),
    do: %{
      caller: "handoff-test",
      run_id: ctx.context.run_id,
      grants: [@name],
      tool_revisions: %{@name => 1}
    }

  defp operation(ctx),
    do: %{
      tool_name: @name,
      tool_revision: 1,
      arguments: ctx.input,
      run_id: ctx.context.run_id,
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: Ecto.UUID.generate()
    }

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
end
