defmodule Synapsis.Agent.Tools.DynamicRuntimeConformanceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{Catalog, Contract, DynamicRuntime, Session}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  # Publication cases retain their recorded 1.10.36 evidence; they were not rerun
  # against 1.10.37. Only the MCP canonical-name round-trip is verified on 1.10.37.
  # Ephemeral Session/Conversation fixtures do not prove production wiring,
  # MCP transport, Code Mode/Deno, or durable session recovery.
  @candidate "host::candidate"
  @outer "host::outer"

  defmodule CandidateBackend do
    def execute(operation) do
      context = operation.backend_context
      count = :ets.update_counter(context.effects, :count, 1)
      send(context.owner, {:candidate_effect, operation, count})
      {:ok, %{content: "candidate executed"}}
    end
  end

  defmodule OuterBackend do
    def execute(operation) do
      context = operation.backend_context

      conflict =
        if context.mode == :reject_stage do
          current = context.catalog_snapshot

          context.stage_catalog.(%{
            publication_id: "fixture-competing-publication",
            run_id: operation.run_id,
            incarnation: operation.incarnation,
            expected_revision: current.revision,
            schema_admission: :strict,
            catalog: Map.put(current, :revision, current.revision + 1)
          })
        end

      nested =
        context.nested_dispatch.(%{
          tool_name: "tool_search",
          arguments: %{"query" => "candidate", "limit" => 1}
        })

      send(context.owner, {:outer_nested_result, operation, conflict, nested, self()})

      receive do
        :finish_outer -> {:ok, %{is_error: true, content: "fixture outer failed"}}
      after
        3_000 -> {:error, Error.new(:timeout, "outer fixture was not released")}
      end
    end
  end

  test "native direct search publishes revision two and dispatches a direct candidate once" do
    ctx = start_run(:direct)
    {first, provider} = provider_request(ctx, 1)
    assert names(first) == ["tool_search"]
    send(provider, {:events, [search("direct-search"), Proof.completed("discover")]})

    {published, provider} = published_request(ctx)

    assert [%{name: @candidate, status: :discovered}] =
             tool_result(published, "direct-search").tools

    assert %{status: :staged, catalog_revision: 2} =
             tool_result(published, "direct-search").publication

    execute_candidate(ctx, provider)
  end

  test "rejected native stage callback keeps the same-owner candidate discoverable" do
    ctx = start_run(:reject_stage)
    {_request, provider} = provider_request(ctx, 1)
    send(provider, {:events, [call("outer-reject", @outer), Proof.completed("reject staging")]})

    assert_receive {:outer_nested_result, outer, {:ok, %{status: :staged}},
                    {:error, %Error{class: :resource_conflict, message: message}}, worker},
                   1_000

    assert message == "another catalog publication is pending"
    assert outer.caller == ctx.authority.caller
    assert outer.run_id == ctx.run_id
    assert outer.incarnation == 1

    assert %{catalog_revision: 1, pending_catalog_publication: %{status: :staged}} =
             Conversation.status(ctx.pid)

    release_outer(worker)
    {retry, provider} = provider_request(ctx, 1)
    assert_discarded(ctx, retry)

    send(
      provider,
      {:events, [search("retry-rejected-search"), Proof.completed("retry discovery")]}
    )

    {published, provider} = published_request(ctx)
    assert [%{name: @candidate}] = tool_result(published, "retry-rejected-search").tools
    execute_candidate(ctx, provider)
  end

  @tag upstream_blocker: "gsmlg-opt/backplane#97"
  test "failed outer settlement discards staging and same-owner native retry publishes the candidate" do
    ctx = start_run(:fail_after_nested)
    {_request, provider} = provider_request(ctx, 1)
    send(provider, {:events, [call("outer-fail", @outer), Proof.completed("nested discovery")]})

    assert_receive {:outer_nested_result, outer, nil, {:ok, nested}, worker}, 1_000
    assert [%{name: @candidate, status: :discovered}] = nested.tools
    assert %{status: :staged, catalog_revision: 2} = nested.publication
    assert outer.caller == ctx.authority.caller
    assert outer.run_id == ctx.run_id
    assert outer.incarnation == 1

    assert %{catalog_revision: 1, pending_catalog_publication: %{status: :staged}} =
             Conversation.status(ctx.pid)

    assert :ets.lookup_element(ctx.effects, :count, 2) == 0

    release_outer(worker)
    {retry, provider} = provider_request(ctx, 1)
    assert_discarded(ctx, retry)
    assert tool_result(retry, "outer-fail").is_error == true

    send(
      provider,
      {:events, [search("retry-discarded-search"), Proof.completed("retry discovery")]}
    )

    # Backplane #97: accepting a staged publication must not permanently hide
    # this owner's candidate when its outer publication boundary later fails.
    {published, provider} = published_request(ctx)
    assert [%{name: @candidate}] = tool_result(published, "retry-discarded-search").tools
    execute_candidate(ctx, provider)
  end

  test "native Contract round-trips the exact existing MCP canonical identity" do
    source_id = "8ba06351-9014-4602-9f0c-f5ab45336c22"
    raw_name = "read_document"
    canonical = "mcp::#{source_id}::#{raw_name}"

    # MCP already dispatches by this exact source UUID/raw-name identity.
    # Use Contract's own public parser and constructor, preserving its namespace;
    # renaming or flattening would change the source-qualified identity.
    assert {:ok, {namespace, name}} = Contract.split_name(canonical)

    assert {:ok, contract} =
             Contract.new(%{
               namespace: namespace,
               name: name,
               tool_revision: 1,
               schema: empty_schema(),
               backend: CandidateBackend,
               safety: safety()
             })

    assert contract.namespace == "mcp"
    assert contract.name == "#{source_id}::#{raw_name}"
    assert contract.tool_name == canonical
    assert Contract.descriptor(contract).tool_name == canonical
    assert Contract.provider_definition(contract).name == canonical
    assert Contract.canonical_name(contract.namespace, contract.name) == canonical
  end

  defp start_run(mode) do
    owner = self()
    run_id = "native-dynamic-#{Ecto.UUID.generate()}"
    effects = :ets.new(__MODULE__, [:set, :public])
    true = :ets.insert(effects, {:count, 0})
    caller = start_supervised!(Task.Supervisor)
    session = start_supervised!({Session, owner_pid: owner, cleanup_timeout: 500})

    candidate = %{
      namespace: "host",
      name: "candidate",
      tool_revision: 1,
      description: "Inert candidate for native discovery acceptance",
      schema: empty_schema(),
      backend: CandidateBackend,
      backend_context: %{owner: owner, effects: effects},
      safety: safety()
    }

    # Keep the public default. :deferred would introduce a separate exposure
    # admission failure and mask publication settlement behavior.
    assert {:ok, %{exposure: :direct}} = Contract.new(candidate)
    runtime = start_supervised!({DynamicRuntime, candidates: [candidate]})
    contracts = DynamicRuntime.contracts(%{dynamic_runtime: runtime})

    contracts =
      if mode == :direct do
        contracts
      else
        contracts ++
          [
            %{
              namespace: "host",
              name: "outer",
              tool_revision: 1,
              schema: empty_schema(),
              backend: OuterBackend,
              backend_context: %{owner: owner, mode: mode},
              safety: safety()
            }
          ]
      end

    authority = %{
      caller: "native-dynamic-proof",
      run_id: run_id,
      grants: Enum.map(contracts, &Contract.canonical_name(&1[:namespace], &1.name)),
      tool_revision: 1
    }

    assert {:ok, bundle} = Catalog.admit(contracts, authority)
    assert {:ok, binding} = Session.bind(session, bundle.authority, incarnation: 1)

    script = fn request ->
      send(owner, {:dynamic_provider, request, self()})

      receive do
        {:events, events} -> events
      after
        3_000 -> raise "native dynamic provider fixture was not released"
      end
    end

    options =
      Proof.options(run_id, script,
        registry: bundle.registry,
        authority: bundle.authority,
        tools: bundle.tools,
        session_binding: binding,
        schema_admission: :strict,
        work: 12,
        effect_timeout: 4_000,
        run_timeout: 15_000
      )

    pid = start_supervised!({Conversation, options})
    on_exit(fn -> Enum.each([pid, runtime, session], &stop_owned/1) end)
    assert {:ok, _} = Proof.prompt(caller, pid, "exercise inert native discovery")

    %{
      pid: pid,
      run_id: run_id,
      authority: bundle.authority,
      effects: effects,
      options: options,
      initial_names: Enum.map(bundle.tools, & &1.name) |> Enum.sort()
    }
  end

  defp provider_request(ctx, revision) do
    run_id = ctx.run_id
    assert_receive {:dynamic_provider, %{run_id: ^run_id} = request, provider}, 1_000
    assert request.catalog_revision == revision
    {request, provider}
  end

  defp published_request(ctx) do
    {request, provider} = provider_request(ctx, 2)
    run_id = ctx.run_id

    assert_receive {:agent_runtime, ^run_id, %{type: :catalog_published, catalog_revision: 2}},
                   1_000

    assert names(request) == Enum.sort([@candidate | ctx.initial_names])
    {request, provider}
  end

  defp assert_discarded(ctx, request) do
    assert names(request) == ctx.initial_names

    assert %{catalog_revision: 1, pending_catalog_publication: nil, catalog_publication: nil} =
             Conversation.status(ctx.pid)

    assert :ets.lookup_element(ctx.effects, :count, 2) == 0
  end

  defp execute_candidate(ctx, provider) do
    send(provider, {:events, [call("candidate-call", @candidate), Proof.completed("execute")]})
    assert_receive {:candidate_effect, operation, 1}, 1_000
    assert operation.catalog_revision == 2
    assert operation.tool_name == @candidate
    assert operation.caller == ctx.authority.caller
    assert operation.run_id == ctx.run_id
    assert operation.incarnation == 1
    assert @candidate in operation.effective_authority.grants
    {_request, provider} = provider_request(ctx, 2)
    send(provider, {:events, [Proof.completed("done")]})
    run_id = ctx.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 1_000
    assert :ets.lookup_element(ctx.effects, :count, 2) == 1
    assert {:ok, persisted} = EphemeralStore.load(ctx.options[:context], run_id)

    assert Enum.count(persisted.run.execution_intents, fn {_id, intent} ->
             intent.type == :tool and intent.operation.tool_name == @candidate
           end) == 1
  end

  defp release_outer(worker) do
    monitor = Process.monitor(worker)
    send(worker, :finish_outer)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end

  defp stop_owned(pid) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      1_000 -> raise "owned native dynamic fixture did not stop"
    end
  end

  defp names(request), do: Enum.map(request.tools, & &1.name) |> Enum.sort()

  defp tool_result(request, id),
    do: Enum.find(request.messages, &(&1[:tool_call_id] == id)).result

  defp search(id),
    do: call(id, "tool_search", %{"query" => "candidate", "limit" => 1})

  defp call(id, name, arguments \\ %{}),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}

  defp empty_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  defp safety, do: %{read_only: true, retry_safe: false, parallel_safe: false}
end
