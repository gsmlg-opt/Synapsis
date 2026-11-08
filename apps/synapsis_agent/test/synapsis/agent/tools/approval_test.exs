defmodule Synapsis.Agent.Tools.ApprovalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, ToolCatalog}
  alias Backplane.AgentRuntime.Approval, as: NativeApproval
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.{Approval, PermissionSnapshot, Policy}

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.owner, {:approval_backend, operation})
      {:ok, %{content: "executed"}}
    end
  end

  setup do
    scope = %{
      caller: "host",
      run_id: "approval-run",
      incarnation: 1,
      catalog_revision: 1,
      session_id: "session",
      requester_id: "operator",
      permission_fingerprint: "permission-v1"
    }

    invocation = %{
      run_id: scope.run_id,
      incarnation: 1,
      catalog_revision: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_call_id: "call",
      turn_id: "turn",
      tool_name: "host::inspect",
      tool_revision: 2,
      arguments: %{"resource" => "document:one"}
    }

    policy = %{
      scope: scope,
      tools: %{
        invocation.tool_name => %{
          tool_revision: 2,
          classify: fn input ->
            {:ok, %{action: "read", resource: input.arguments["resource"]}}
          end
        }
      },
      decisions: %{{invocation.tool_name, "read", "document:one"} => :ask}
    }

    state = start_supervised!({Agent, fn -> nil end})
    owner = self()

    context = %{
      tool_scope: scope,
      tool_policy: policy,
      tool_readiness: %{
        scope: scope,
        tools: %{invocation.tool_name => %{tool_revision: 2, status: :ready}}
      },
      input_kind: :function,
      tool_approval: %{
        mode: :interactive,
        scope: scope,
        expires_at: System.system_time(:millisecond) + 60_000,
        refresh: fn -> {:ok, Agent.get(state, & &1)} end
      },
      interact: fn request ->
        send(owner, {:approval_request, request})
        {:ok, :approved}
      end
    }

    Agent.update(state, fn _ -> context end)
    %{invocation: invocation, context: context, state: state}
  end

  test "native approval rejects missing, blank and nonbinary resolvers for either decision",
       ctx do
    for outcome <- [:approved, :denied] do
      {approval, decision} = native_approval_decision(ctx.invocation, outcome)
      resolvers = [nil, "", " \t\r\n", "\u00A0\u2003", :untrusted, 42, false, %{}, []]
      invalid_decisions = Enum.map(resolvers, &Map.put(decision, :resolver_id, &1))

      for invalid <- [decision | invalid_decisions] do
        assert {:error,
                %Error{
                  class: :validation,
                  message: "resolver identity must be a nonblank binary"
                }} = NativeApproval.decide(approval, invalid)
      end
    end
  end

  test "native approval forbids the model resolver for either decision", ctx do
    for outcome <- [:approved, :denied] do
      {approval, decision} = native_approval_decision(ctx.invocation, outcome)

      assert {:error, %Error{class: :forbidden, message: "model cannot self-approve"}} =
               NativeApproval.decide(approval, Map.put(decision, :resolver_id, approval.run_id))
    end
  end

  test "native approval accepts opaque host identity structure without authenticating it", ctx do
    for outcome <- [:approved, :denied], resolver <- ["authenticated-host", " host ", <<255>>] do
      {approval, decision} = native_approval_decision(ctx.invocation, outcome)

      assert {:ok, ^outcome} =
               NativeApproval.decide(approval, Map.put(decision, :resolver_id, resolver))
    end
  end

  test "dynamic ask preserves pinned input and requests serializable native interaction", ctx do
    assert :allow = Policy.prepare_tool(ctx.invocation, ctx.context)
    assert_receive {:approval_request, request}
    assert request.kind == :permission
    assert request.operation === ctx.invocation
    assert request.scope === ctx.context.tool_scope
    assert request.action == "read"
    assert request.resource == "document:one"
    assert request.expires_at == ctx.context.tool_approval.expires_at
    assert {:ok, _} = Jason.encode(request)
    refute Map.has_key?(request, :refresh)
    refute Map.has_key?(request.operation, :backend_context)
  end

  test "missing context, unattended mode and untrusted scope never request approval", ctx do
    assert {:deny, :approval_required} =
             Policy.prepare_tool(ctx.invocation, Map.delete(ctx.context, :tool_approval))

    for context <- [
          put_in(ctx.context, [:tool_approval, :mode], :autonomous),
          put_in(ctx.context, [:tool_approval, :scope, :requester_id], "another"),
          update_in(ctx.context, [:tool_approval, :scope], &Map.delete(&1, :session_id)),
          update_in(ctx.context, [:tool_approval], &Map.delete(&1, :refresh)),
          Map.delete(ctx.context, :interact)
        ] do
      assert {:deny, _} = Policy.prepare_tool(ctx.invocation, context)
    end

    refute_receive {:approval_request, _}, 0
  end

  test "denial, malformed answers and input edits never authorize", ctx do
    for answer <- [
          :denied,
          true,
          :allow,
          %{decision: :approved},
          {:update_input, %{"resource" => "other"}}
        ] do
      context = %{ctx.context | interact: fn _ -> {:ok, answer} end}
      assert {:deny, :approval_denied} = Policy.prepare_tool(ctx.invocation, context)
    end
  end

  test "blank trusted host identities are refused before an interaction", ctx do
    for field <- [:caller, :run_id, :session_id, :requester_id] do
      scope = Map.put(ctx.context.tool_scope, field, " \t")
      invocation = %{ctx.invocation | run_id: scope.run_id}

      context =
        ctx.context
        |> Map.put(:tool_scope, scope)
        |> put_in([:tool_policy, :scope], scope)
        |> put_in([:tool_readiness, :scope], scope)
        |> put_in([:tool_approval, :scope], scope)

      assert {:deny, :approval_unavailable} = Policy.prepare_tool(invocation, context)
      refute_receive {:approval_request, _}, 0
    end
  end

  test "absolute host expiry is checked before requesting and after resolution", ctx do
    expired =
      put_in(ctx.context, [:tool_approval, :expires_at], System.system_time(:millisecond) - 1)

    assert {:deny, :approval_expired} = Policy.prepare_tool(ctx.invocation, expired)
    refute_receive {:approval_request, _}, 0

    context = %{
      ctx.context
      | interact: fn _ ->
          Agent.update(
            ctx.state,
            &put_in(&1, [:tool_approval, :expires_at], System.system_time(:millisecond) - 1)
          )

          {:ok, :approved}
        end
    }

    assert {:deny, :approval_expired} = Policy.prepare_tool(ctx.invocation, context)
  end

  test "refresh cannot extend deadline or change requester, fingerprint or classification", ctx do
    for current <- [
          put_in(
            ctx.context,
            [:tool_approval, :expires_at],
            ctx.context.tool_approval.expires_at + 1
          ),
          put_in(ctx.context, [:tool_approval, :scope, :requester_id], "another"),
          put_in(ctx.context, [:tool_scope, :permission_fingerprint], "permission-v2"),
          put_in(ctx.context, [:tool_approval, :mode], :autonomous),
          put_in(ctx.context, [:tool_policy, :tools, "host::inspect", :classify], fn _ ->
            {:ok, %{action: "write", resource: "document:one"}}
          end)
          |> put_in([:tool_policy, :decisions], %{
            {"host::inspect", "write", "document:one"} => :ask
          })
        ] do
      Agent.update(ctx.state, fn _ -> current end)
      assert {:deny, _} = Policy.prepare_tool(ctx.invocation, ctx.context)
    end
  end

  test "fresh deny, unavailable readiness and refresh errors fail closed", ctx do
    denied =
      put_in(ctx.context, [:tool_policy, :decisions], %{
        {"host::inspect", "read", "document:one"} => :deny
      })

    Agent.update(ctx.state, fn _ -> denied end)
    assert {:deny, :policy_denied} = Policy.prepare_tool(ctx.invocation, ctx.context)

    unavailable =
      put_in(
        ctx.context,
        [:tool_readiness, :tools, "host::inspect", :status],
        {:unavailable, :credential_revoked}
      )

    Agent.update(ctx.state, fn _ -> unavailable end)

    assert {:deny, {:unavailable, "host::inspect", :credential_revoked}} =
             Policy.prepare_tool(ctx.invocation, ctx.context)

    context = put_in(ctx.context, [:tool_approval, :refresh], fn -> {:error, :unavailable} end)
    assert {:deny, :approval_refresh_failed} = Policy.prepare_tool(ctx.invocation, context)
  end

  test "raw custom input remains immutable", ctx do
    invocation = %{ctx.invocation | arguments: "opaque input"}
    context = %{ctx.context | input_kind: :custom}

    context =
      put_in(context, [:tool_policy, :tools, "host::inspect", :classify], fn input ->
        assert input.arguments === "opaque input"
        {:ok, %{action: "read", resource: "document:one"}}
      end)

    Agent.update(ctx.state, fn _ -> context end)
    assert :allow = Policy.prepare_tool(invocation, context)
    assert_receive {:approval_request, %{operation: %{arguments: "opaque input"}}}
  end

  test "ephemeral values never enter persisted interaction request", ctx do
    for invocation <- [
          Map.put(ctx.invocation, :backend_context, %{pid: self()}),
          put_in(ctx.invocation, [:arguments, "resource"], self())
        ] do
      assert {:deny, _} = Policy.prepare_tool(invocation, ctx.context)
    end

    refute_receive {:approval_request, _}, 0
  end

  test "native resolver authenticates exact host scope and invocation before dispatch", ctx do
    {pid, options} = start_conversation(ctx)
    {id, request} = pending(pid)
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []
    trusted = %{scope: request.scope, operation: request.operation}

    for invalid <- [
          put_in(trusted, [:scope, :requester_id], "another"),
          put_in(trusted, [:scope, :session_id], "another"),
          put_in(trusted, [:scope, :incarnation], 2),
          put_in(trusted, [:operation, :arguments, "resource"], "document:other"),
          put_in(trusted, [:operation, :tool_revision], 3)
        ] do
      assert {:error, %Error{}} = Approval.resolve(pid, id, :approved, invalid)
    end

    assert {:error, %Error{}} = Approval.resolve(pid, "stale", :approved, trusted)
    assert {:error, %Error{}} = Approval.resolve(pid, id, {:update_input, %{}}, trusted)
    assert :ok = Approval.resolve(pid, id, :approved, trusted)
    assert_receive {:approval_backend, operation}, 1_000
    assert operation.arguments === request.operation.arguments
    assert operation.invocation_id === request.operation.invocation_id
    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    assert length(tool_intents(options)) == 1
    assert {:error, %Error{}} = Approval.resolve(pid, id, :approved, trusted)
  end

  test "compiled session permission asks before native intent and dispatches exactly once", ctx do
    permission = %Synapsis.SessionPermission{
      session_id: ctx.context.tool_scope.session_id,
      tool_contract_version: 1,
      mode: :interactive,
      allow_read: :ask,
      allow_write: :deny,
      allow_execute: :deny,
      allow_destructive: :deny,
      tool_overrides: %{}
    }

    scope =
      Map.put(
        ctx.context.tool_scope,
        :permission_fingerprint,
        PermissionSnapshot.fingerprint(permission)
      )

    targets = [
      %{
        tool: "host::inspect",
        action: "read",
        resource: "document:one",
        permission_level: :read
      }
    ]

    assert {:ok, policy} =
             PermissionSnapshot.compile(permission, scope, ctx.context.tool_policy.tools, targets)

    assert policy.decisions == %{{"host::inspect", "read", "document:one"} => :ask}

    context =
      ctx.context
      |> Map.put(:tool_scope, scope)
      |> Map.put(:tool_policy, policy)
      |> put_in([:tool_readiness, :scope], scope)
      |> put_in([:tool_approval, :scope], scope)

    Agent.update(ctx.state, fn _ -> context end)
    {pid, options} = start_conversation(%{ctx | context: context})
    {id, request} = pending(pid)
    assert request.scope === scope
    assert request.action == "read"
    assert request.resource == "document:one"
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []

    trusted = %{scope: scope, operation: request.operation}
    assert :ok = Approval.resolve(pid, id, :approved, trusted)
    assert_receive {:approval_backend, operation}, 1_000
    assert operation.arguments === request.operation.arguments
    assert operation.invocation_id === request.operation.invocation_id
    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    assert length(tool_intents(options)) == 1
    assert {:error, %Error{}} = Approval.resolve(pid, id, :approved, trusted)
    refute_receive {:approval_backend, _}, 0
    assert length(tool_intents(options)) == 1
  end

  test "native raw malformed and edit answers cannot authorize preparation", ctx do
    for answer <- [%{decision: :approved}, {:update_input, %{"resource" => "document:other"}}] do
      {pid, options} = start_conversation(ctx)
      {id, _request} = pending(pid)
      assert tool_intents(options) == []
      refute_receive {:approval_backend, _}, 0

      assert :ok = Conversation.resolve(pid, id, answer)
      assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
      assert tool_intents(options) == []
      refute_receive {:approval_backend, _}, 0
    end
  end

  test "native denial and cancellation cannot dispatch or reuse an answer", ctx do
    for decision <- [:denied, :cancel] do
      {pid, options} = start_conversation(ctx)
      {id, request} = pending(pid)
      trusted = %{scope: request.scope, operation: request.operation}

      if decision == :cancel do
        assert :ok = Conversation.cancel(pid)
        assert_receive {:agent_runtime, "approval-run", %{type: :run_cancelled}}, 1_000
      else
        assert :ok = Approval.resolve(pid, id, :denied, trusted)
        assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
      end

      assert {:error, %Error{}} = Approval.resolve(pid, id, :approved, trusted)
      refute_receive {:approval_backend, _}, 0
      assert tool_intents(options) == []
    end
  end

  test "native wait rechecks current policy and readiness before invocation intent", ctx do
    {pid, options} = start_conversation(ctx)
    {id, request} = pending(pid)

    Agent.update(
      ctx.state,
      &put_in(&1, [:tool_readiness, :tools, "host::inspect", :status], {:unavailable, :revoked})
    )

    assert :ok =
             Approval.resolve(pid, id, :approved, %{
               scope: request.scope,
               operation: request.operation
             })

    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []
  end

  test "host consent cannot bypass final native schema validation", ctx do
    invocation = put_in(ctx.invocation, [:arguments, "unrecognized"], true)
    {pid, options} = start_conversation(%{ctx | invocation: invocation})
    {id, request} = pending(pid)

    assert :ok =
             Approval.resolve(pid, id, :approved, %{
               scope: request.scope,
               operation: request.operation
             })

    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []
  end

  test "host expiry refuses native resolution while the human wait remains pending", ctx do
    context =
      put_in(ctx.context, [:tool_approval, :expires_at], System.system_time(:millisecond) + 2_000)

    Agent.update(ctx.state, fn _ -> context end)
    {pid, options} = start_conversation(%{ctx | context: context})
    {id, request} = pending(pid)
    Process.sleep(max(0, request.expires_at - System.system_time(:millisecond) + 1))
    assert Conversation.status(pid).phase == :waiting_interaction

    assert {:error, %Error{}} =
             Approval.resolve(pid, id, :approved, %{
               scope: request.scope,
               operation: request.operation
             })

    assert :ok = Conversation.resolve(pid, id, :approved)
    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []
  end

  test "a shorter refreshed deadline is checked again after classification", ctx do
    context =
      put_in(ctx.context, [:tool_approval, :expires_at], System.system_time(:millisecond) + 100)

    context =
      put_in(context, [:tool_policy, :tools, "host::inspect", :classify], fn _ ->
        Process.sleep(
          max(0, context.tool_approval.expires_at - System.system_time(:millisecond) + 1)
        )

        {:ok, %{action: "read", resource: "document:one"}}
      end)

    Agent.update(ctx.state, fn _ -> context end)
    assert {:deny, :approval_expired} = Policy.prepare_tool(ctx.invocation, ctx.context)
  end

  test "built-in native approval remains an independent second gate", ctx do
    {pid, options} = start_conversation(ctx, true)
    {id, request} = pending(pid)

    assert :ok =
             Approval.resolve(pid, id, :approved, %{
               scope: request.scope,
               operation: request.operation
             })

    {native_id, native_request} = pending(pid)
    refute native_id == id
    assert native_request.kind == :permission
    assert native_request.operation === request.operation
    refute_receive {:approval_backend, _}, 0
    assert tool_intents(options) == []
    assert :ok = Conversation.resolve(pid, native_id, :approved)
    assert_receive {:approval_backend, _}, 1_000
    assert_receive {:agent_runtime, "approval-run", %{type: :run_completed}}, 1_000
    assert length(tool_intents(options)) == 1
  end

  defp native_approval_decision(invocation, outcome) do
    now = System.monotonic_time(:millisecond)

    approval = %{
      approval_id: "native-resolver-contract",
      run_id: invocation.run_id,
      tool_name: invocation.tool_name,
      tool_revision: invocation.tool_revision,
      arguments_digest:
        :crypto.hash(:sha256, :erlang.term_to_binary(invocation.arguments))
        |> Base.encode16(case: :lower),
      current_time: now,
      expires_at: now + 60_000
    }

    decision =
      approval
      |> Map.take([:approval_id, :tool_name, :tool_revision, :arguments_digest])
      |> Map.put(:decision, outcome)

    {approval, decision}
  end

  defp start_conversation(ctx, native_approval \\ false) do
    descriptor = %{
      tool_name: "host::inspect",
      tool_revision: 2,
      description: "Inert approval probe",
      schema: %{
        "type" => "object",
        "properties" => %{"resource" => %{"type" => "string"}},
        "required" => ["resource"],
        "additionalProperties" => false
      },
      backend: Backend,
      backend_context: %{owner: self()},
      safety: %{
        read_only: false,
        retry_safe: false,
        parallel_safe: false,
        requires_approval: native_approval
      }
    }

    authority = %{
      caller: "host",
      run_id: "approval-run",
      grants: [descriptor.tool_name],
      tool_revision: 2
    }

    {:ok, bundle} = ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority)

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("done")],
        else: [
          Proof.call(descriptor.tool_name, ctx.invocation.arguments),
          Proof.completed("calling")
        ]
    end

    options =
      Proof.options("approval-run", script,
        registry: bundle.registry,
        authority: bundle.authority,
        tools: bundle.tools,
        hooks: Policy,
        provider_context: Map.put(ctx.context, :script, script),
        schema_admission: :strict
      )

    pid = start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
    assert {:ok, _} = Conversation.prompt(pid, "try tool")
    {pid, options}
  end

  defp pending(_pid) do
    assert_receive {:agent_runtime, "approval-run",
                    %{type: :interaction_requested, interaction_id: id, request: request}},
                   1_000

    {id, request}
  end

  defp tool_intents(options) do
    {:ok, persisted} = EphemeralStore.load(options[:context], "approval-run")
    persisted.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end
end
