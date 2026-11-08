defmodule Synapsis.Agent.Tools.SessionPresenceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    ToolCatalog
  }

  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.{ResultProjection, SessionPresence}
  alias Synapsis.Session.Store

  @discover "synapsis::agent_discover"
  @status "synapsis::agent_status"
  @names [@discover, @status]

  setup do
    assert Code.ensure_loaded?(SessionPresence),
           "native session presence tools are not implemented"

    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()

    :ok =
      Store.put_meta(id, %{id: id, agent: "configured owner", config: %{token: "private config"}})

    {:ok, _} =
      Registry.register(Synapsis.Session.Registry, id, %{
        token: "private registry",
        agent_id: "wrong owner"
      })

    on_exit(fn -> Store.delete_session(id) end)

    %{
      context: %{
        session_id: id,
        agent_id: "configured observer",
        run_id: "/root/研究者:1",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "revision-one descriptors expose read-only bounded UUID discovery",
       ctx do
    assert SessionPresence.names() == @names
    assert {:ok, [discover, status] = descriptors} = SessionPresence.descriptors(ctx.context)

    for descriptor <- descriptors do
      assert descriptor.tool_revision === 1
      assert descriptor.backend == SessionPresence
      assert descriptor.backend_context === ctx.context
      assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
      assert descriptor.schema["additionalProperties"] == false
      assert SessionPresence.permission_level(descriptor.tool_name) == :none
    end

    assert Enum.sort(Map.keys(discover.schema["properties"])) ==
             ~w(action agent_id cursor limit owner_agent_id type)

    assert discover.schema["required"] == ["action"]
    assert discover.schema["properties"]["action"]["enum"] == ~w(list get find_by_agent)
    assert discover.schema["properties"]["limit"]["maximum"] == 100
    assert discover.schema["properties"]["agent_id"]["description"] =~ "UUID"
    assert discover.schema["properties"]["owner_agent_id"]["description"] =~ "configured"
    assert String.downcase(discover.description) =~ "bounded"
    refute String.downcase(discover.description) =~ "unavailable"
    refute discover.schema["properties"]["cursor"]["description"] =~ "unavailable"
    assert Map.keys(status.schema["properties"]) == ["session_id"]
    assert status.description =~ "Build Agent system not yet implemented"

    assert {:ok, _} =
             ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
  end

  test "pure classification selects session UUID independently of observer and opaque native run",
       ctx do
    target = Ecto.UUID.generate()

    for {name, args, action} <- [
          {@discover, %{"action" => "get", "agent_id" => target}, "session.presence.get"},
          {@discover, %{"action" => "list", "limit" => 10}, "session.presence.list"},
          {@discover, %{"action" => "find_by_agent", "owner_agent_id" => "configured owner"},
           "session.presence.find_by_agent"},
          {@status, %{"session_id" => target}, "session.presence.status"}
        ] do
      assert {:ok, %{action: ^action, resource: "session_presence:" <> resource}} =
               SessionPresence.classify(ctx.context, operation(ctx, name, args))

      parsed = Jason.decode!(resource)
      assert parsed["observer_session_id"] == ctx.context.session_id
      refute resource =~ ctx.context.run_id

      if Map.has_key?(args, "agent_id") or Map.has_key?(args, "session_id"),
        do: assert(parsed["session_id"] == target)
    end
  end

  @tag :model_visible_result
  test "native Execution returns only registration observation and raw persisted configured owner",
       ctx do
    assert {:ok, _, %{effects: [result]}} =
             native(ctx, @discover, %{"action" => "get", "agent_id" => ctx.context.session_id})

    refute Map.get(result, :is_error, false)

    assert result.structured.session == %{
             session_id: ctx.context.session_id,
             kind: "session_worker",
             registered: true,
             alive: true,
             owner_agent_id: "configured owner",
             owner_known: true
           }

    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    encoded = Jason.encode!(result.structured)

    for forbidden <- ["private", "wrong owner", "pid", ctx.context.run_id, "running", "children"] do
      refute encoded =~ forbidden
    end

    assert byte_size(encoded) <= 65_536
    assert {:ok, _} = ResultProjection.to_part("presence", {:ok, result}, tool_name: @discover)

    missing = Ecto.UUID.generate()

    assert {:ok,
            %{
              structured: %{
                session: %{
                  session_id: ^missing,
                  registered: false,
                  alive: false,
                  owner_known: false
                }
              }
            }} =
             SessionPresence.execute(
               operation(ctx, @discover, %{"action" => "get", "agent_id" => missing})
             )
  end

  @tag :model_visible_result
  test "status preserves unsupported build agents and optionally observes the requested session",
       ctx do
    assert {:ok, %{structured: result}} = SessionPresence.execute(operation(ctx, @status, %{}))

    assert result == %{
             build_agents_supported: false,
             agents: [],
             message: "Build Agent system not yet implemented."
           }

    assert {:ok, _, %{effects: [selected]}} =
             native(ctx, @status, %{"session_id" => ctx.context.session_id})

    assert Jason.decode!(selected.content) == Jason.decode!(Jason.encode!(selected.structured))
    assert selected.structured.build_agents_supported == false
    assert selected.structured.agents == []
    assert selected.structured.session.registered
    refute Map.has_key?(selected.structured.session, :build_status)
  end

  @tag :model_visible_result
  test "native Execution enumerates live sessions and filters configured owners without leaking metadata",
       ctx do
    for args <- [
          %{"action" => "list", "limit" => 1},
          %{"action" => "list", "type" => "session_worker", "limit" => 1},
          %{"action" => "find_by_agent", "owner_agent_id" => "configured owner", "limit" => 1}
        ] do
      args = Map.put(args, "cursor", previous_uuid(ctx.context.session_id))
      assert {:ok, _, %{effects: [result]}} = native(ctx, @discover, args)
      refute Map.get(result, :is_error, false)
      assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
      assert result.structured.count == 1
      assert [session] = result.structured.sessions
      assert session.session_id == ctx.context.session_id
      assert session.owner_agent_id == "configured owner"
      assert session.registered and session.alive
      encoded = Jason.encode!(result.structured)
      assert byte_size(encoded) <= 65_536

      for forbidden <- ["private", "wrong owner", "pid", ctx.context.run_id] do
        refute encoded =~ forbidden
      end

      assert {:ok, _} = ResultProjection.to_part("presence", {:ok, result}, tool_name: @discover)
    end

    assert {:ok, _, %{effects: [wrong_owner]}} =
             native(ctx, @discover, %{
               "action" => "find_by_agent",
               "owner_agent_id" => "wrong owner"
             })

    refute Map.get(wrong_owner, :is_error, false)
    assert wrong_owner.structured.sessions == []

    assert Jason.decode!(wrong_owner.content) ==
             Jason.decode!(Jason.encode!(wrong_owner.structured))

    assert {:ok, %{structured: %{sessions: [], count: 0}}} =
             SessionPresence.execute(
               operation(ctx, @discover, %{"action" => "list", "type" => "build_agent"})
             )
  end

  test "closed trusted context and model input cannot select storage, registry or native identities",
       ctx do
    for changed <- [
          Map.put(ctx.context, :registry, AnotherRegistry),
          Map.put(ctx.context, :store, AnotherStore),
          Map.put(ctx.context, :primary, true),
          %{ctx.context | agent_id: ""},
          %{ctx.context | session_id: ctx.context.run_id}
        ] do
      assert {:error, %Error{}} = SessionPresence.descriptors(changed)
    end

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 2,
          tool_revision: 1.0
        ] do
      op = Map.put(operation(ctx, @status, %{}), key, value)
      assert {:error, :scope_mismatch} = SessionPresence.classify(ctx.context, op)
      assert {:error, %Error{}} = SessionPresence.execute(op)
    end

    for args <- [
          %{"action" => "get", "agent_id" => ctx.context.run_id},
          %{"action" => "list", "registry" => "forged"},
          %{"action" => "list", "limit" => 101},
          %{"action" => "list", "type" => "build_agent", "limit" => 0},
          %{"action" => "list", "cursor" => "opaque-run"},
          %{"action" => "find_by_agent"}
        ] do
      assert {:error, :invalid_input} =
               SessionPresence.classify(ctx.context, operation(ctx, @discover, args))

      assert {:error, %Error{class: :validation}} =
               SessionPresence.execute(operation(ctx, @discover, args))
    end

    for args <- [
          %{"session_id" => ctx.context.run_id},
          %{"agent_id" => ctx.context.session_id},
          %{"registry" => "forged"}
        ] do
      assert {:error, :invalid_input} =
               SessionPresence.classify(ctx.context, operation(ctx, @status, args))

      assert {:error, %Error{class: :validation}} =
               SessionPresence.execute(operation(ctx, @status, args))
    end

    op = operation(ctx, @status, %{})

    enriched = %{
      op
      | backend_context:
          Map.merge(ctx.context, %{
            resource_owner_pid: self(),
            interact: fn _ -> raise "must not interact" end
          })
    }

    assert {:ok, _} = SessionPresence.execute(enriched)
    assert :ok = SessionPresence.cancel(op)
  end

  test "missing grants and wrong revisions fail before native Execution intent", ctx do
    {:ok, descriptors} = SessionPresence.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))

    for {name, args} <- [
          {@status, %{}},
          {@discover, %{"action" => "list"}},
          {@discover, %{"action" => "find_by_agent", "owner_agent_id" => "configured owner"}}
        ],
        input = Map.drop(operation(ctx, name, args), [:backend_context]),
        {changed, changed_authority} <- [
          {input, %{bundle.authority | grants: []}},
          {%{input | tool_revision: 2}, bundle.authority}
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
  end

  test "Conversation executes both presence adapters with native context enrichment", ctx do
    {:ok, descriptors} = SessionPresence.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))

    calls = [
      {@discover, %{"action" => "get", "agent_id" => ctx.context.session_id}},
      {@discover,
       %{"action" => "list", "limit" => 1, "cursor" => previous_uuid(ctx.context.session_id)}},
      {@discover,
       %{
         "action" => "find_by_agent",
         "owner_agent_id" => "configured owner",
         "limit" => 1,
         "cursor" => previous_uuid(ctx.context.session_id)
       }},
      {@status, %{}}
    ]

    script = fn request ->
      index = Enum.count(request.messages, &(&1.role == :tool))

      case Enum.at(calls, index) do
        {name, args} ->
          [
            put_in(Proof.call(name, args), [:tool_call, :id], "presence-#{index}"),
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
        effect_timeout: 2_000
      )

    pid = start_supervised!({Conversation, opts})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Observe session registration")
    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000

    assert [discovered, listed, filtered, status] =
             Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))

    refute Map.get(discovered.result, :is_error, false)
    refute Map.get(listed.result, :is_error, false)
    refute Map.get(filtered.result, :is_error, false)
    refute Map.get(status.result, :is_error, false)
    assert discovered.result.structured.session.owner_agent_id == "configured owner"

    assert Enum.map(listed.result.structured.sessions, & &1.session_id) == [
             ctx.context.session_id
           ]

    assert Enum.map(filtered.result.structured.sessions, & &1.session_id) == [
             ctx.context.session_id
           ]

    assert status.result.structured.build_agents_supported == false
    {:ok, persisted} = EphemeralStore.load(opts[:context], run_id)
    assert Enum.count(Map.values(persisted.run.execution_intents), &(&1.type == :tool)) == 4
  end

  defp previous_uuid(id) do
    previous = id |> String.replace("-", "") |> String.to_integer(16) |> Kernel.-(1)
    hex = previous |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
      hex

    Enum.join([a, b, c, d, e], "-")
  end

  defp native(ctx, name, args) do
    {:ok, descriptors} = SessionPresence.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})
    input = Map.drop(operation(ctx, name, args), [:backend_context])

    Execution.run(EphemeralStore, table, record(ctx), %{command: {:tool_invoked, 11, input}},
      registry: bundle.registry,
      authority: bundle.authority,
      budget: budget,
      effect_timeout: 2_000,
      commit_timeout: 500,
      cleanup_timeout: 500
    )
  end

  defp authority(ctx),
    do: %{
      caller: "presence-test",
      run_id: ctx.context.run_id,
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
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

  defp operation(ctx, name, args),
    do: %{
      tool_name: name,
      tool_revision: 1,
      arguments: args,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: Ecto.UUID.generate()
    }
end
