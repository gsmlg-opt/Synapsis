defmodule Synapsis.Agent.Tools.MCPResourcesFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{Backend, ResourceRegistry, Session}
  alias Synapsis.Agent.Tools.MCPResources

  @names ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)

  test "selected resource descriptors retain native contracts and reuse one Session-owned runtime" do
    session = start_supervised!({Session, owner_pid: self()})

    authority = %{
      caller: "resource-fixture",
      run_id: "resource-run",
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    identity = %{
      caller: authority.caller,
      run_id: authority.run_id,
      incarnation: 1,
      session_id: "host-session",
      catalog_revision: 1
    }

    context = %{agent: %{tools: @names}}

    assert {:ok, [first], cache} =
             MCPResources.bundles(context, identity, authority, @names, binding, %{})

    key = {binding.owner_id, binding.incarnation}
    assert %{^key => %{binding: ^binding, pid: pid, handle: handle}} = cache

    assert {:ok, ^pid} =
             ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id)

    assert {:ok, native} =
             Codex.profile(:dynamic, %{dynamic_runtime: pid, session_binding: binding}, authority,
               tools: @names
             )

    assert Enum.sort(Map.keys(first.registry.tools)) == Enum.sort(@names)

    for name <- @names do
      descriptor = first.registry.tools[name]
      original = native.registry.tools[name]
      assert descriptor.backend == Backend
      assert descriptor.tool_name == original.tool_name
      assert descriptor.tool_revision == original.tool_revision
      assert descriptor.schema == original.schema
      assert descriptor.backend_context.family == :dynamic
      assert descriptor.backend_context.runtime == pid
      assert descriptor.backend_context.session_binding == binding
    end

    assert {:ok, [second], ^cache} =
             MCPResources.bundles(context, identity, authority, @names, binding, cache)

    assert second.registry.tools == first.registry.tools
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    refute Process.alive?(pid)
  end

  test "an ordinary selection without resource tools creates no runtime" do
    assert {:ok, [], %{}} =
             MCPResources.bundles(
               %{agent: %{tools: []}},
               %{},
               %{grants: [], tool_revisions: %{}},
               [],
               nil,
               %{}
             )
  end
end
