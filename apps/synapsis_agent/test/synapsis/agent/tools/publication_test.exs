defmodule Synapsis.Agent.Tools.PublicationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolCatalog}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  defmodule Backend do
    def execute(operation) do
      context = operation.backend_context
      committed = EphemeralStore.load(context.table, operation.run_id)
      send(context.owner, {:publication_backend, operation, self(), committed})
      await_result(context)
    end

    defp await_result(context) do
      receive do
        {:stage, update} ->
          send(context.owner, {:publication_receipt, context.stage_catalog.(update)})
          await_result(context)

        {:finish, result} ->
          result
      after
        5_000 -> {:error, Error.new(:execution_failure, "publication probe timed out")}
      end
    end
  end

  test "publication waits for the pinned batch and admits the discovered tool exactly once" do
    ctx = start_run()
    {producer, worker} = start_discovery(ctx, [call("old-batch-new", "host::new")])
    assert producer.catalog_revision == 1
    assert producer.backend_context.catalog_snapshot.revision == 1

    assert Map.keys(producer.backend_context.catalog_snapshot.registry.tools) == [
             "host::discover"
           ]

    stage(worker, ctx.update)
    assert_staged(ctx)
    assert {:ok, %{status: :staged}} = Conversation.stage_catalog(ctx.pid, ctx.update)
    assert tool_names(ctx) == ["host::discover"]
    refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0
    refute_receive {:agent_runtime, "publication-run", %{type: :catalog_published}}, 0

    send(worker, {:finish, {:ok, %{content: "discovered"}}})

    assert_receive {:agent_runtime, "publication-run",
                    %{type: :catalog_published, catalog_revision: 2}},
                   1_000

    assert_receive {:publication_provider, request, provider}, 1_000
    assert request.catalog_revision == 2
    assert Enum.map(request.tools, & &1.name) == ["host::discover", "host::new"]
    assert List.last(request.messages).tool_call_id == "old-batch-new"
    assert List.last(request.messages).result.is_error == true
    assert tool_names(ctx) == ["host::discover"]
    refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0

    assert {:error, %Error{class: :resource_conflict}} =
             producer.backend_context.stage_catalog.(ctx.update)

    send(provider, {:events, [call("new-batch-new", "host::new"), Proof.completed("use new")]})
    assert_receive {:publication_backend, operation, new_worker, {:ok, persisted}}, 1_000
    assert operation.tool_name == "host::new"
    assert operation.catalog_revision == 2
    assert operation.effective_authority.grants == ["host::discover", "host::new"]
    assert_committed(persisted, operation)
    send(new_worker, {:finish, {:ok, %{content: "executed"}}})
    finish_run(ctx, 2)

    assert tool_names(ctx) == ["host::discover", "host::new"]
    assert Conversation.status(ctx.pid).pending_catalog_publication == nil
    assert Conversation.status(ctx.pid).catalog_publication == receipt(:published)
    assert {:ok, published} = Conversation.stage_catalog(ctx.pid, ctx.update)
    assert published == receipt(:published)
    refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0
    refute_receive {:agent_runtime, "publication-run", %{type: :catalog_published}}, 0
    assert tool_names(ctx) == ["host::discover", "host::new"]
  end

  test "failed and error-marked producers discard staging without admitting new effects" do
    for result <- [
          {:error, Error.new(:execution_failure, "discovery failed")},
          {:ok, %{is_error: true, content: "discovery failed"}},
          {:ok, %{"is_error" => true, "content" => "discovery failed"}}
        ] do
      ctx = start_run()
      {_producer, worker} = start_discovery(ctx)
      stage(worker, ctx.update)
      assert_staged(ctx)
      send(worker, {:finish, result})
      finish_run(ctx, 1)

      assert_unpublished(ctx)

      assert {:error, %Error{class: :resource_conflict}} =
               Conversation.stage_catalog(ctx.pid, ctx.update)
    end
  end

  test "cancellation discards the staged receipt and fences the producer" do
    ctx = start_run()
    {producer, worker} = start_discovery(ctx)
    monitor = Process.monitor(worker)
    stage(worker, ctx.update)
    assert_staged(ctx)

    assert :ok = Conversation.cancel(ctx.pid)
    assert_receive {:agent_runtime, "publication-run", %{type: :run_cancelled}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert_unpublished(ctx)

    assert {:error, %Error{class: :resource_conflict}} =
             producer.backend_context.stage_catalog.(ctx.update)

    assert {:error, %Error{class: :resource_conflict}} =
             Conversation.stage_catalog(ctx.pid, ctx.update)
  end

  test "stale revisions, foreign runs/incarnations and conflicting publications are atomic" do
    ctx = start_run()
    {producer, worker} = start_discovery(ctx)

    for {update, class, message} <- [
          {%{ctx.update | expected_revision: 2}, :resource_conflict, "catalog revision is stale"},
          {%{ctx.update | run_id: "foreign-run"}, :resource_conflict,
           "catalog publication belongs to another run"},
          {%{ctx.update | incarnation: 2}, :resource_conflict,
           "catalog publication belongs to another incarnation"},
          {put_in(ctx.update, [:catalog, :revision], 3), :validation,
           "catalog revision must advance by one"}
        ] do
      assert {:error, %Error{class: ^class, message: ^message}} =
               producer.backend_context.stage_catalog.(update)

      assert Conversation.status(ctx.pid).catalog_revision == 1
      assert Conversation.status(ctx.pid).pending_catalog_publication == nil
      assert tool_names(ctx) == ["host::discover"]
      refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0
      refute_receive {:agent_runtime, "publication-run", %{type: :catalog_published}}, 0
    end

    stage(worker, ctx.update)
    assert_staged(ctx)

    for {update, message} <- [
          {%{ctx.update | expected_revision: 2},
           "publication id was already used for another catalog"},
          {%{ctx.update | publication_id: "competing"}, "another catalog publication is pending"}
        ] do
      assert {:error, %Error{class: :resource_conflict, message: ^message}} =
               Conversation.stage_catalog(ctx.pid, update)

      assert_staged(ctx)
      assert tool_names(ctx) == ["host::discover"]
    end

    send(worker, {:finish, {:ok, %{content: "discovered"}}})
    finish_run(ctx, 2)
    assert Conversation.status(ctx.pid).catalog_publication == receipt(:published)
    assert tool_names(ctx) == ["host::discover"]
    refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0
  end

  defp start_run do
    owner = self()

    script = fn request ->
      send(owner, {:publication_provider, request, self()})

      receive do
        {:events, events} -> events
      after
        5_000 -> raise "publication provider probe timed out"
      end
    end

    options = Proof.options("publication-run", script, work: 10, effect_timeout: 3_000)
    context = %{owner: owner, table: options[:context]}
    discover = descriptor("host::discover", context)
    {:ok, initial} = admit([discover])
    {:ok, revised} = admit([discover, descriptor("host::new", context)])

    options =
      Keyword.merge(options,
        registry: initial.registry,
        authority: initial.authority,
        tools: initial.tools,
        schema_admission: :strict
      )

    pid = start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
    assert {:ok, _} = Conversation.prompt(pid, "discover")

    update = %{
      publication_id: "catalog-2",
      run_id: "publication-run",
      incarnation: 1,
      expected_revision: 1,
      schema_admission: :strict,
      catalog: %{
        revision: 2,
        registry: revised.registry,
        authority: revised.authority,
        tools: revised.tools
      }
    }

    %{pid: pid, options: options, update: update}
  end

  defp descriptor(name, context) do
    %{
      tool_name: name,
      tool_revision: 1,
      description: "Inert publication probe",
      schema: Proof.EchoTool.parameters(),
      backend: Backend,
      backend_context: context,
      safety: %{read_only: true, retry_safe: false, parallel_safe: false}
    }
  end

  defp admit(descriptors) do
    authority = %{
      caller: "publication-proof",
      run_id: "publication-run",
      grants: Enum.map(descriptors, & &1.tool_name),
      tool_revision: 1
    }

    ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority)
  end

  defp call(id, name) do
    Proof.call(name, %{"text" => "probe"})
    |> put_in([:tool_call, :id], id)
  end

  defp start_discovery(ctx, rest \\ []) do
    assert_receive {:publication_provider, request, provider}, 1_000
    assert request.catalog_revision == 1
    assert Enum.map(request.tools, & &1.name) == ["host::discover"]

    send(
      provider,
      {:events, [call("discover", "host::discover") | rest] ++ [Proof.completed("discovering")]}
    )

    assert_receive {:publication_backend, operation, worker, {:ok, persisted}}, 1_000
    assert operation.tool_name == "host::discover"
    assert_committed(persisted, operation)
    assert tool_names(ctx) == ["host::discover"]
    {operation, worker}
  end

  defp stage(worker, update) do
    send(worker, {:stage, update})
    assert_receive {:publication_receipt, {:ok, staged}}, 1_000
    assert staged == receipt(:staged)
  end

  defp assert_staged(ctx) do
    status = Conversation.status(ctx.pid)
    assert status.catalog_revision == 1
    assert status.catalog_publication == nil
    assert status.pending_catalog_publication == receipt(:staged)
  end

  defp finish_run(_ctx, revision) do
    assert_receive {:publication_provider, request, provider}, 1_000
    assert request.catalog_revision == revision
    expected = if revision == 1, do: ["host::discover"], else: ["host::discover", "host::new"]
    assert Enum.map(request.tools, & &1.name) == expected
    send(provider, {:events, [Proof.completed("done")]})
    assert_receive {:agent_runtime, "publication-run", %{type: :run_completed}}, 1_000
  end

  defp assert_unpublished(ctx) do
    status = Conversation.status(ctx.pid)
    assert status.catalog_revision == 1
    assert status.catalog_publication == nil
    assert status.pending_catalog_publication == nil
    assert tool_names(ctx) == ["host::discover"]
    refute_receive {:publication_backend, %{tool_name: "host::new"}, _, _}, 0
    refute_receive {:agent_runtime, "publication-run", %{type: :catalog_published}}, 0
  end

  defp receipt(status),
    do: %{publication_id: "catalog-2", catalog_revision: 2, status: status}

  defp assert_committed(persisted, operation) do
    intent = persisted.run.execution_intents["tool:#{operation.invocation_id}"]
    assert intent.type == :tool
    assert intent.operation.tool_name == operation.tool_name
    assert intent.operation.arguments == operation.arguments
    assert intent.operation.catalog_revision == operation.catalog_revision
  end

  defp tool_names(ctx) do
    {:ok, persisted} = EphemeralStore.load(ctx.options[:context], "publication-run")

    persisted.run.execution_intents
    |> Map.values()
    |> Enum.filter(&(&1.type == :tool))
    |> Enum.map(& &1.operation.tool_name)
    |> Enum.sort()
  end
end
