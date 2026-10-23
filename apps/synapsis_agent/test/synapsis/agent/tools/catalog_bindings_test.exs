defmodule Synapsis.Agent.Tools.CatalogBindingsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Contract, MultiAgent}
  alias Synapsis.Agent.Tools.Catalog

  @parent %{
    run_id: "catalog-run",
    run_incarnation: 1,
    owner_id: "catalog-session",
    incarnation: 1
  }

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.owner, :unexpected_backend_effect)
      MultiAgent.call_bound(operation, operation.arguments)
    end
  end

  setup do
    manager = start_manager()
    descriptors = Enum.map([:list, :wait], &bind(manager, &1))

    authority = %{
      caller: "catalog-test",
      run_id: @parent.run_id,
      grants: Enum.map(descriptors, & &1.tool_name),
      tool_revisions: Map.new(descriptors, &{&1.tool_name, &1.tool_revision}),
      tool_bindings: Map.new(descriptors, &{&1.tool_name, &1.collaboration_binding.fingerprint})
    }

    assert :ok = MultiAgent.rebind_parent(manager, @parent, authority)

    assert {:ok, native} =
             ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

    %{manager: manager, native: native, authority: authority, descriptor: hd(descriptors)}
  end

  test "composition preserves the admitted fingerprint and manager context for bound calls",
       ctx do
    name = ctx.descriptor.tool_name
    assert {:ok, composed} = Catalog.compose([ctx.native], [], ctx.authority, [name])
    assert composed.registry.tools[name] == ctx.descriptor

    assert composed.registry.tools[name].collaboration_binding ==
             ctx.descriptor.collaboration_binding

    assert composed.registry.tools[name].backend_context.runtime == ctx.manager

    assert composed.authority.tool_bindings == %{
             name => ctx.descriptor.collaboration_binding.fingerprint
           }

    assert {:ok, readmitted} =
             ToolCatalog.admit_batch([ctx.descriptor],
               authority: composed.authority,
               mode: :strict
             )

    assert readmitted == composed
    operation = operation(composed.registry.tools[name], composed.authority)
    assert {:ok, %{agents: []}} = MultiAgent.call_bound(operation, %{})
    refute_receive :unexpected_backend_effect, 0
    refute_receive :unexpected_child_preparation, 0
  end

  test "explicit selection narrows binding grants along with tools and revisions", ctx do
    name = ctx.descriptor.tool_name

    authority =
      ctx.authority
      |> put_in([:tool_bindings, "unselected"], "unselected-fingerprint")
      |> Map.put("tool_bindings", ctx.authority.tool_bindings)

    assert {:ok, composed} = Catalog.compose([ctx.native], [], authority, [name])
    expected = %{name => ctx.descriptor.collaboration_binding.fingerprint}
    assert Map.keys(composed.registry.tools) == [name]
    assert composed.authority.grants == [name]
    assert composed.authority.tool_revisions == %{name => ctx.descriptor.tool_revision}
    assert composed.authority.tool_bindings == expected
    assert composed.authority["tool_bindings"] == expected
  end

  test "none and empty selection remove every binding grant", ctx do
    authority = Map.put(ctx.authority, "tool_bindings", ctx.authority.tool_bindings)

    for selection <- [:none, []] do
      assert {:ok, composed} = Catalog.compose([ctx.native], [], authority, selection)
      assert composed.registry.tools == %{}
      assert composed.tools == []
      assert composed.authority.grants == []
      assert composed.authority.tool_revisions == %{}
      assert composed.authority.tool_bindings == %{}
      assert composed.authority["tool_bindings"] == %{}
    end
  end

  test "a source bundle cannot replace missing or stale target binding authority", ctx do
    name = ctx.descriptor.tool_name

    for authority <- [
          Map.delete(ctx.authority, :tool_bindings),
          %{ctx.authority | tool_bindings: %{}},
          put_in(ctx.authority, [:tool_bindings, name], String.duplicate("0", 64))
        ] do
      assert {:error, %Error{class: :forbidden}} =
               Catalog.compose([ctx.native], [], authority, [name])
    end

    refute_receive :unexpected_backend_effect, 0
  end

  test "forged descriptor identity cannot reuse a binding grant", ctx do
    descriptor = ctx.descriptor
    name = descriptor.tool_name

    for forged <- [
          Map.delete(descriptor, :collaboration_binding),
          put_in(descriptor.collaboration_binding.action, :wait),
          put_in(descriptor.collaboration_binding.manager_id, "another-manager"),
          put_in(descriptor.schema["description"], "changed schema"),
          put_in(descriptor.safety.read_only, false)
        ] do
      assert {:error, %Error{class: :forbidden}} =
               Catalog.compose([], [forged], ctx.authority, [name])
    end

    forged = put_in(descriptor.collaboration_binding.fingerprint, String.duplicate("0", 64))

    authority =
      put_in(ctx.authority, [:tool_bindings, name], forged.collaboration_binding.fingerprint)

    assert {:error, %Error{class: :forbidden}} =
             Catalog.compose([], [forged], authority, [name])

    refute_receive :unexpected_backend_effect, 0
  end

  test "a replacement manager cannot reuse the previous fingerprint or invocation", ctx do
    replacement = start_manager()
    descriptor = bind(replacement, :list)
    name = descriptor.tool_name
    refute descriptor.collaboration_binding == ctx.descriptor.collaboration_binding

    assert {:error, %Error{class: :forbidden}} =
             Catalog.compose([], [descriptor], ctx.authority, [name])

    assert {:ok, composed} = Catalog.compose([ctx.native], [], ctx.authority, [name])

    stale =
      composed.registry.tools[name]
      |> operation(composed.authority)
      |> put_in([:backend_context, :runtime], replacement)

    assert {:ok, before} = MultiAgent.snapshot(replacement)
    assert {:rejected, proof} = MultiAgent.call_bound(stale, %{})

    assert {:ok, %{error: %Error{class: :forbidden}}} =
             ToolEffects.validate_rejection(proof, stale)

    assert {:ok, ^before} = MultiAgent.snapshot(replacement)
    refute_receive :unexpected_backend_effect, 0
    refute_receive :unexpected_child_preparation, 0
  end

  defp start_manager do
    owner = self()

    start_supervised!(
      Supervisor.child_spec(
        {MultiAgent,
         parent_run_id: @parent.run_id,
         parent_name: "/root",
         parent_authority: %{caller: "catalog-test", run_id: @parent.run_id, grants: []},
         child_options: fn _, _, _ ->
           send(owner, :unexpected_child_preparation)
           {:error, Error.new(:execution_failure, "child execution is outside this test")}
         end},
        id: make_ref()
      )
    )
  end

  defp bind(manager, action) do
    assert {:ok, contract} =
             MultiAgent.bind_contract(manager, action, %{
               namespace: "host",
               name: "sessions_#{action}",
               tool_revision: 3,
               backend: Backend,
               backend_context: %{
                 owner: self(),
                 resource_owner: Map.take(@parent, [:owner_id, :incarnation])
               },
               schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
               safety: %{read_only: true, retry_safe: false, parallel_safe: false}
             })

    Contract.descriptor(contract)
  end

  defp operation(descriptor, authority) do
    %{
      run_id: @parent.run_id,
      incarnation: @parent.run_incarnation,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_call_id: "call",
      turn_id: "turn",
      catalog_revision: 1,
      tool_name: descriptor.tool_name,
      tool_revision: descriptor.tool_revision,
      collaboration_binding: descriptor.collaboration_binding,
      arguments: %{},
      backend_context: descriptor.backend_context,
      effective_authority: authority,
      caller: authority.caller
    }
  end
end
