defmodule Synapsis.Agent.Tools.PolicyTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.Policy

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test_pid, {:policy_backend, operation.arguments})
      {:ok, %{content: "executed"}}
    end
  end

  setup do
    scope = %{caller: "host", run_id: "policy-run", incarnation: 1, catalog_revision: 1}

    invocation =
      Map.merge(Map.drop(scope, [:caller]), %{
        tool_name: "native::read",
        tool_revision: 2,
        arguments: %{"resource" => "document:one"}
      })

    classifier = fn input -> {:ok, %{action: "read", resource: input.arguments["resource"]}} end

    policy = %{
      scope: scope,
      tools: %{"native::read" => %{tool_revision: 2, classify: classifier}},
      decisions: %{{"native::read", "read", "document:one"} => :allow}
    }

    readiness = %{scope: scope, tools: %{"native::read" => %{tool_revision: 2, status: :ready}}}

    context = %{
      tool_scope: scope,
      tool_policy: policy,
      tool_readiness: readiness,
      input_kind: :function
    }

    %{invocation: invocation, context: context}
  end

  test "exact authorization preserves function and custom inputs", ctx do
    assert :allow = Policy.prepare_tool(ctx.invocation, ctx.context)
    invocation = %{ctx.invocation | arguments: "opaque custom input"}

    context =
      put_in(ctx.context, [:tool_policy, :tools, "native::read", :classify], fn input ->
        assert input.arguments == "opaque custom input"
        {:ok, %{action: "read", resource: "document:one"}}
      end)

    assert :allow = Policy.prepare_tool(invocation, %{context | input_kind: :custom})
  end

  test "explicit deny and ask stay closed without approval resolution", ctx do
    for {decision, reason} <- [deny: :policy_denied, ask: :approval_required] do
      context =
        put_in(ctx.context, [:tool_policy, :decisions], %{
          {"native::read", "read", "document:one"} => decision
        })

      assert {:deny, ^reason} = Policy.prepare_tool(ctx.invocation, context)
    end
  end

  test "pure evaluation retains the exact ask target without requesting consent", ctx do
    context =
      put_in(ctx.context, [:tool_policy, :decisions], %{
        {"native::read", "read", "document:one"} => :ask
      })

    context =
      Map.put(context, :interact, fn _ -> flunk("evaluation requested an interaction") end)

    assert {:ok, %{decision: :ask, action: "read", resource: "document:one"}} =
             Policy.evaluate(ctx.invocation, context)
  end

  test "tool action and resource are exact and classifications in arguments are untrusted", ctx do
    for decisions <- [
          %{},
          %{{"other", "read", "document:one"} => :allow},
          %{{"native::read", "write", "document:one"} => :allow},
          %{{"native::read", "read", "document:*"} => :allow}
        ] do
      context = put_in(ctx.context, [:tool_policy, :decisions], decisions)

      invocation = %{
        ctx.invocation
        | arguments:
            Map.merge(ctx.invocation.arguments, %{
              "permission" => "allow",
              "action" => "write",
              "resource_class" => "safe"
            })
      }

      assert {:deny, :missing_decision} = Policy.prepare_tool(invocation, context)
    end
  end

  test "missing sidecars tools and unsupported legacy classifications fail closed", ctx do
    for key <- [:tool_scope, :tool_policy, :tool_readiness] do
      assert {:deny, _} = Policy.prepare_tool(ctx.invocation, Map.delete(ctx.context, key))
    end

    assert {:deny, :unknown_tool} =
             Policy.prepare_tool(%{ctx.invocation | tool_name: "other"}, ctx.context)

    context =
      put_in(ctx.context, [:tool_policy, :tools, "native::read", :classify], fn _ ->
        {:ok, :read}
      end)

    assert {:deny, :unsupported_classification} = Policy.prepare_tool(ctx.invocation, context)

    context =
      put_in(ctx.context, [:tool_policy, :decisions], %{
        {"native::read", "read", "document:one"} => :legacy_grant
      })

    assert {:deny, :unsupported_decision} = Policy.prepare_tool(ctx.invocation, context)
  end

  test "scope and revision drift are refused before classification", ctx do
    context =
      put_in(ctx.context, [:tool_policy, :tools, "native::read", :classify], fn _ ->
        flunk("stale evidence reached classifier")
      end)

    for {field, value} <- [run_id: "other", incarnation: 2, catalog_revision: 2, tool_revision: 3] do
      assert {:deny, _} = Policy.prepare_tool(Map.put(ctx.invocation, field, value), context)
    end

    for field <- [:caller, :run_id, :incarnation, :catalog_revision] do
      sidecar = put_in(context, [:tool_policy, :scope, field], :stale)
      assert {:deny, :scope_mismatch} = Policy.prepare_tool(ctx.invocation, sidecar)
    end
  end

  test "unavailable readiness retains the host reason", ctx do
    context =
      put_in(
        ctx.context,
        [:tool_readiness, :tools, "native::read", :status],
        {:unavailable, :provider_disabled}
      )

    assert {:deny, {:unavailable, "native::read", :provider_disabled}} =
             Policy.prepare_tool(ctx.invocation, context)
  end

  test "numeric scope identity uses exact types", ctx do
    for field <- [:incarnation, :catalog_revision] do
      invocation = Map.put(ctx.invocation, field, 1.0)
      assert {:deny, :scope_mismatch} = Policy.prepare_tool(invocation, ctx.context)
      context = put_in(ctx.context, [:tool_policy, :scope, field], 1.0)
      assert {:deny, :scope_mismatch} = Policy.prepare_tool(ctx.invocation, context)
    end
  end

  for {case_name, decision, executes?, evidence_revision} <- [
        {:allow, :allow, true, 2},
        {:deny, :deny, false, 2},
        {:ask, :ask, false, 2},
        {:stale_readiness, :allow, false, 3}
      ] do
    test "native Conversation #{case_name} preparation controls backend and invocation intent",
         ctx do
      context =
        put_in(ctx.context, [:tool_policy, :decisions], %{
          {"native::read", "read", "document:one"} => unquote(decision)
        })

      context =
        put_in(
          context,
          [:tool_readiness, :tools, "native::read", :tool_revision],
          unquote(evidence_revision)
        )

      descriptor = %{
        tool_name: "native::read",
        tool_revision: 2,
        description: "Inert preparation probe",
        schema: %{
          "type" => "object",
          "properties" => %{"resource" => %{"type" => "string"}},
          "required" => ["resource"],
          "additionalProperties" => false
        },
        backend: Backend,
        backend_context: %{test_pid: self()},
        safety: %{read_only: false, retry_safe: false, parallel_safe: false}
      }

      authority = %{
        caller: "host",
        run_id: "policy-run",
        grants: ["native::read"],
        tool_revision: 2
      }

      {:ok, bundle} = ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority)

      script = fn request ->
        if Enum.any?(request.messages, &(&1.role == :tool)),
          do: [Proof.completed("done")],
          else: [Proof.call("native::read", ctx.invocation.arguments), Proof.completed("calling")]
      end

      options =
        Proof.options("policy-run", script,
          registry: bundle.registry,
          authority: bundle.authority,
          tools: bundle.tools,
          hooks: Policy,
          provider_context: Map.put(context, :script, script),
          schema_admission: :strict
        )

      pid = start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
      caller = start_supervised!(Task.Supervisor)
      assert {:ok, _} = Proof.prompt(caller, pid, "try tool")
      assert_receive {:agent_runtime, "policy-run", %{type: :run_completed}}, 2_000
      {:ok, persisted} = EphemeralStore.load(options[:context], "policy-run")
      intents = Map.values(persisted.run.execution_intents)
      tool_intents = Enum.filter(intents, &(&1.type == :tool))

      if unquote(executes?) do
        assert_receive {:policy_backend, %{"resource" => "document:one"}}
        assert length(tool_intents) == 1
      else
        refute_receive {:policy_backend, _}, 20
        assert tool_intents == []
        result = Conversation.status(pid).messages |> Enum.find(&(&1.role == :tool))
        assert result.result.is_error
      end
    end
  end
end
