defmodule Synapsis.Agent.Runtime.ToolRegistryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Runtime.{ToolBackend, ToolRegistry}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof.EchoTool
  alias Synapsis.Tool.Registry
  alias Synapsis.Tool.Capability.PolicySnapshot

  setup do
    name = "catalog-#{Ecto.UUID.generate()}"
    :ok = Registry.register_module(name, EchoTool)
    on_exit(fn -> Registry.unregister(name) end)
    {:ok, registration} = Registry.lookup(name)

    tool = %{
      name: name,
      description: EchoTool.description(),
      parameters: EchoTool.parameters(),
      registration: registration
    }

    context = %{run_id: Ecto.UUID.generate(), project_path: File.cwd!(), tool_profile: :coding}
    %{tool: tool, context: context}
  end

  test "freezes registration, policy, schema and revision with conservative safety", ctx do
    context =
      Map.merge(ctx.context, %{operator_approval: true, capability_grant: :untrusted, input: %{}})

    assert {:ok, admitted} = admit([ctx.tool], context)

    assert admitted.authority == %{
             caller: "test",
             run_id: context.run_id,
             grants: [ctx.tool.name],
             tool_revision: 7
           }

    assert admitted.tools == [Map.take(ctx.tool, [:name, :description, :parameters])]
    descriptor = admitted.registry.tools[ctx.tool.name]
    assert descriptor.backend == ToolBackend
    assert descriptor.schema == ctx.tool.parameters
    assert descriptor.tool_revision == 7
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert descriptor.backend_context.registration == ctx.tool.registration
    host = descriptor.backend_context.host_context
    assert %PolicySnapshot{} = host.policy_snapshot
    refute Map.has_key?(host, :operator_approval)
    refute Map.has_key?(host, :capability_grant)
    refute Map.has_key?(host, :input)
  end

  test "rejects duplicate, unbound, stale and mismatched definitions", ctx do
    assert {:error, %Error{class: :validation}} = admit([ctx.tool, ctx.tool], ctx.context)

    assert {:error, %Error{class: :validation}} =
             admit([Map.delete(ctx.tool, :registration)], ctx.context)

    assert {:error, %Error{class: :resource_conflict}} =
             admit([%{ctx.tool | parameters: %{}}], ctx.context)

    :ok = Registry.register_module(ctx.tool.name, EchoTool, version: "changed")
    assert {:error, %Error{class: :resource_conflict}} = admit([ctx.tool], ctx.context)
  end

  test "rejects unsupported schemas without removing keywords", ctx do
    schema = %{"type" => "object", "patternProperties" => %{".*" => %{"type" => "string"}}}
    :ok = Registry.register_module(ctx.tool.name, EchoTool, parameters: schema)
    {:ok, registration} = Registry.lookup(ctx.tool.name)
    tool = %{ctx.tool | registration: registration, parameters: schema}
    assert {:error, %Error{}} = admit([tool], ctx.context)
  end

  test "rejects process tools, discovery, deferred and disabled registrations", ctx do
    assert {:error, %Error{class: :unsupported_capability}} =
             admit([%{ctx.tool | registration: {:process, self(), []}}], ctx.context)

    assert {:error, %Error{class: :unsupported_capability}} =
             admit([%{ctx.tool | name: "tool_search"}], ctx.context)

    for {opts, class} <- [
          {[deferred: true], :unsupported_capability},
          {[enabled: false], :forbidden}
        ] do
      :ok = Registry.register_module(ctx.tool.name, EchoTool, opts)
      {:ok, registration} = Registry.lookup(ctx.tool.name)

      assert {:error, %Error{class: ^class}} =
               admit([%{ctx.tool | registration: registration}], ctx.context)
    end
  end

  test "fails admission for invalid authority, deadlines, safety and policy scope", ctx do
    for {key, value} <- [run_id: "", project_path: "relative"] do
      assert {:error, %Error{class: :validation}} =
               admit([ctx.tool], Map.put(ctx.context, key, value))
    end

    for opts <- [
          [revision: 0],
          [caller: ""],
          [tool_timeout_ms: :infinity],
          [approval_timeout_ms: 0]
        ] do
      assert {:error, %Error{class: :validation}} = admit([ctx.tool], ctx.context, opts)
    end

    for safety <- [nil, %{retry_safe: "yes"}] do
      assert {:error, %Error{class: :validation}} =
               admit([Map.put(ctx.tool, :safety, safety)], ctx.context)
    end

    for scope <- [[run_id: "another"], [session_id: "another"]] do
      context =
        Map.put(ctx.context, :policy_snapshot, PolicySnapshot.from_permission_mode("ask", scope))

      assert {:error, %Error{class: :forbidden}} = admit([ctx.tool], context)
    end
  end

  defp admit(tools, context, opts \\ []),
    do: ToolRegistry.admit(tools, context, Keyword.merge([revision: 7, caller: "test"], opts))
end
