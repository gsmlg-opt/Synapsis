defmodule Synapsis.Agent.Tools.DiscoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{Contract, ResourceRegistry, Session}
  alias Synapsis.Agent.Tools.{Discovery, Profiles}

  defmodule Backend do
    def execute(_), do: {:ok, %{content: "ordinary candidate"}}
  end

  test "empty and explicit plans preserve selected names while deriving only native search" do
    names = ["exec", "wait", "clock::curr_time"]
    assert {:ok, empty} = Discovery.plan(%{}, names)
    assert empty.initial == names
    assert empty.runtime == names
    assert empty.deferred == []
    assert {:ok, plan} = Discovery.plan(%{deferred_tool_names: ["clock::curr_time"]}, names)
    assert plan.selected == names
    assert plan.runtime == names ++ ["tool_search"]
    assert plan.initial == ["exec", "wait", "tool_search"]

    assert {:ok, child} =
             Discovery.plan(%{deferred_tool_names: ["clock::curr_time"]}, names, %{
               grants: ["exec", "wait", "tool_search"]
             })

    assert child.selected == ["exec", "wait"]
    assert child.deferred == []
    assert child.initial == ["exec", "wait"]
  end

  test "native control-only discovery retains full issued inventory and exact MCP/custom/direct-only contracts" do
    session = start_supervised!({Session, owner_pid: self()})
    name = "mcp::#{Ecto.UUID.generate()}::read*(literal)?::raw"
    names = [name, "exec", "wait", "host::media"]

    authority = %{
      caller: "discovery-positive",
      run_id: Ecto.UUID.generate(),
      grants: names ++ ["tool_search"],
      tool_revision: 1,
      tool_revisions: Map.new(names ++ ["tool_search"], &{&1, 1})
    }

    assert {:ok, binding} = Session.bind(session, authority)

    assert {:ok, native} =
             Codex.profile(
               :code_mode,
               %{session_binding: binding},
               %{
                 authority
                 | grants: ~w(exec wait),
                   tool_revisions: Map.take(authority.tool_revisions, ~w(exec wait))
               },
               tools: ~w(exec wait)
             )

    attrs = %{
      name: "media",
      namespace: "host",
      schema: schema(),
      backend: Backend,
      backend_context: %{original: :media},
      safety: safety(),
      exposure: :direct_model_only
    }

    {:ok, media} = Contract.new(attrs)
    {:ok, {namespace, local}} = Contract.split_name(name)

    {:ok, candidate} =
      Contract.new(%{
        attrs
        | name: local,
          namespace: namespace,
          backend_context: %{original: :mcp},
          exposure: :direct
      })

    descriptors =
      Map.values(native.registry.tools) ++
        [Contract.descriptor(media), Contract.descriptor(candidate)]

    selected_authority = %{
      authority
      | grants: names,
        tool_revisions: Map.take(authority.tool_revisions, names)
    }

    assert {:ok, full} =
             ToolCatalog.admit_batch(descriptors, authority: selected_authority, mode: :strict)

    assert {:ok, plan} =
             Discovery.plan(%{deferred_tool_names: [name, "exec", "host::media"]}, names)

    assert {:ok, issued, initial, record} = Discovery.prepare(full, plan, binding, authority)
    assert Enum.sort(Map.keys(initial.registry.tools)) == ~w(tool_search wait)
    assert Enum.sort(Map.keys(issued.registry.tools)) == Enum.sort(names ++ ["tool_search"])
    assert initial.registry.tools["tool_search"].backend_context.family == :dynamic
    assert initial.registry.tools["tool_search"].backend_context.session_binding == binding
    assert issued.registry.tools["exec"].codex_input_kind == :custom
    assert issued.registry.tools["exec"].codex_format == full.registry.tools["exec"].codex_format
    assert issued.registry.tools["host::media"].codex_exposure == :direct_model_only
    assert issued.registry.tools[name].backend_context == %{original: :mcp}
    assert {:ok, {namespace, local}} = Contract.split_name(name)
    assert namespace <> "::" <> local == name
    assert issued.registry.tools[name].tool_name == name

    identity = %{
      caller: authority.caller,
      session_id: "ordinary",
      run_id: authority.run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    snapshot = %{
      scope: identity,
      issued_descriptors: issued.registry.tools,
      selected: %{},
      known_bindings: %{}
    }

    # Generic fixture classifiers are never executed in this representation check.
    initial_catalog = %{
      revision: 1,
      registry: initial.registry,
      authority: initial.authority,
      tools: initial.tools
    }

    assert {:ok, projected} = Profiles.project_catalog(identity, snapshot, initial_catalog)
    assert Enum.sort(Map.keys(projected.selected)) == ~w(tool_search wait)

    later = %{
      revision: 2,
      registry: issued.registry,
      authority: issued.authority,
      tools: issued.tools
    }

    assert {:ok, projected} =
             Profiles.project_catalog(%{identity | catalog_revision: 2}, snapshot, later)

    assert Enum.sort(Map.keys(projected.selected)) == Enum.sort(names ++ ["tool_search"])

    assert {:ok, pid} =
             ResourceRegistry.fetch(binding.resource_registry, record.handle, binding.owner_id)

    assert pid == record.pid
    monitor = Process.monitor(pid)
    assert :ok = Discovery.release(record)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  defp safety, do: %{read_only: true, retry_safe: true, parallel_safe: true}
end
