defmodule Synapsis.Agent.Tools.ProfilesTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Error}
  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Synapsis.Agent.Tools.{Policy, Profiles, WorkspaceMemory}
  alias Synapsis.Session.Store

  @get "synapsis::workspace_memory_get"
  @search "synapsis::workspace_memory_search"
  @skills "synapsis::skills_read"
  @explicit_skill "synapsis::skill"
  @mail ~w(synapsis::agent_send synapsis::agent_ask synapsis::agent_reply synapsis::agent_inbox)
  @swarm ~w(synapsis::swarm_message synapsis::teammate synapsis::team_delete)
  @presence ~w(synapsis::agent_discover synapsis::agent_status)
  @handoff "synapsis::agent_handoff"
  @directory "synapsis::agents_list"
  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Store.ensure_started()
    session = Ecto.UUID.generate()

    raw = %Synapsis.SessionPermission{
      session_id: session,
      allow_read: :allow,
      tool_contract_version: 1
    }

    :ok = Store.put_value(session, "permission", raw)
    on_exit(fn -> Store.delete_session(session) end)

    identity = %{
      caller: "profile-test",
      session_id: session,
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      catalog_revision: 1
    }

    context = %{
      session: %{id: session, config: %{"subagents" => false}},
      agent: %{tools: [@get], tool_contract_version: 1},
      project_path: root
    }

    ceiling = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: [@get, @search, @skills],
      tool_revisions: %{@get => 1, @search => 1, @skills => 1}
    }

    invocation =
      Map.merge(Map.take(identity, [:run_id, :incarnation, :catalog_revision]), %{
        tool_name: @get,
        tool_revision: 1,
        arguments: %{"path" => "MEMORY.md"}
      })

    %{context: context, identity: identity, ceiling: ceiling, invocation: invocation, raw: raw}
  end

  test "selection preserves explicit emptiness and rejects implicit or ambiguous selections",
       ctx do
    assert {:ok, []} = Profiles.selection(put_in(ctx.context, [:agent, :tools], []))

    for tools <- [nil, :all, "default", [@get, @get], ["*"]] do
      assert {:error, %Error{}} = Profiles.selection(put_in(ctx.context, [:agent, :tools], tools))
    end

    enabled = put_in(ctx.context, [:session, :config], %{})
    assert {:ok, [@get]} = Profiles.selection(enabled)
    assert {:ok, []} = Profiles.selection(put_in(enabled, [:agent, :tools], []))

    assert {:ok, ["list_agents"]} =
             Profiles.selection(put_in(enabled, [:agent, :tools], ["list_agents"]))

    assert {:error, %Error{}} =
             Profiles.selection(put_in(ctx.context, [:agent, :tools], ["spawn_agent"]))
  end

  @tag :contract_version
  test "selection independently rejects legacy missing malformed and empty native versions",
       ctx do
    session = %{ctx.context.session | config: %{}}

    for names <- [["send_message"], []], version <- [0, nil, "1", 2, 1.0] do
      agent = %{tools: names, tool_contract_version: version}

      assert {:error, %Error{class: :validation}} =
               Profiles.selection(%{agent: agent, session: session})

      assert {:error, %Error{class: :validation}} =
               Profiles.selection(%{
                 agent: Map.delete(agent, :tool_contract_version),
                 session: session
               })
    end

    for names <- [["send_message"], []] do
      assert {:ok, ^names} =
               Profiles.selection(%{
                 agent: %{tools: names, tool_contract_version: 1},
                 session: session
               })
    end
  end

  @tag :contract_version
  test "invalid version is rejected before MCP descriptor or backend construction", ctx do
    for names <- [["send_message"], []] do
      agent = %{tools: names, tool_contract_version: 0, mcp_sources: :must_not_inspect}
      context = %{ctx.context | agent: agent, session: %{ctx.context.session | config: %{}}}

      assert {:error, %Error{class: :validation, message: message}} =
               Profiles.build(context, ctx.identity, :must_not_build, ctx.ceiling)

      assert message =~ "version"
    end
  end

  test "exact catalog retains native backend and scopes preparation without execution input edits",
       ctx do
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert bundle.registry.tools[@get].backend == WorkspaceMemory
    assert snapshot.skill_snapshot == nil
    assert Map.has_key?(snapshot.known_bindings, @skills)
    refute Map.has_key?(ctx.invocation, :backend_context)

    assert {:ok, sidecars} = Profiles.prepare_context(ctx.invocation, snapshot)

    assert sidecars.tool_policy.decisions == %{
             {@get, "memory.read", "memory:workspace:#{ctx.context.project_path}:file:MEMORY.md"} =>
               :allow
           }

    assert :allow = Policy.prepare_tool(ctx.invocation, Map.put(sidecars, :input_kind, :function))
    refute Map.has_key?(ctx.invocation, :backend_context)
    assert snapshot.scope.catalog_revision == ctx.identity.catalog_revision
  end

  test "all unavailable names fail visibly before catalog admission", ctx do
    context = put_in(ctx.context, [:agent, :tools], [@get, "unknown::one", "unknown::two"])

    assert {:error, %Error{message: message, details: %{tools: missing}}} =
             Profiles.build(context, ctx.identity, [], ctx.ceiling)

    assert missing == ["unknown::one", "unknown::two"]
    assert message =~ "unknown::one"
    assert message =~ "unknown::two"
  end

  test "an unresolved saved toolset cannot become an empty or partial native selection", ctx do
    agent = %{tools: [], tool_selection_error: {:toolsets_unavailable, [Ecto.UUID.generate()]}}
    assert {:error, %Error{}} = Profiles.selection(%{ctx.context | agent: agent})
  end

  test "known unselected restrictions are retained and unknown overrides deny preparation", ctx do
    raw = %{ctx.raw | tool_overrides: %{@skills => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{snapshot: snapshot}} = build(ctx)
    assert snapshot.permission.tool_overrides == %{@skills => :deny}
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)

    raw = %{raw | tool_overrides: %{"unknown::restricted" => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{snapshot: snapshot}} = build(ctx)

    assert {:error, {:unbound_override, "unknown::restricted"}} =
             Profiles.prepare_context(ctx.invocation, snapshot)
  end

  test "permission and invocation revision changes fail before preparation", ctx do
    assert {:ok, %{snapshot: snapshot}} = build(ctx)

    for {field, value} <- [
          run_id: "another",
          incarnation: 2,
          catalog_revision: 2,
          tool_revision: 2
        ] do
      assert {:error, _} =
               Profiles.prepare_context(Map.put(ctx.invocation, field, value), snapshot)
    end

    :ok = Store.put_value(ctx.identity.session_id, "permission", %{ctx.raw | allow_read: :deny})
    assert {:error, :freshness_changed} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  test "production resolver denies ask and never inherits fixture approval grants", ctx do
    :ok = Store.put_value(ctx.identity.session_id, "permission", %{ctx.raw | allow_read: :ask})
    assert {:ok, %{snapshot: snapshot}} = build(ctx)

    context = %{
      input_kind: :function,
      tool_context_resolver: fn invocation ->
        assert invocation === ctx.invocation
        {:ok, snapshot}
      end,
      tool_approval: %{mode: :interactive},
      interact: fn _ -> flunk("unauthenticated approval requested") end
    }

    assert {:deny, :approval_required} = Policy.prepare_tool(ctx.invocation, context)

    assert {:deny, :tool_context_unavailable} =
             Policy.prepare_tool(ctx.invocation, %{
               context
               | tool_context_resolver: fn _ -> exit(:unavailable) end
             })
  end

  test "default collaboration keeps admitted native descriptors and orchestration permissions",
       ctx do
    {context, ceiling, native} = collaboration(ctx)

    raw = %{
      ctx.raw
      | allow_read: :deny,
        allow_write: :deny,
        allow_execute: :deny,
        allow_destructive: :deny
    }

    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, ctx.identity, [native], ceiling)

    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(@collaboration)

    for {name, descriptor} <- native.registry.tools do
      assert bundle.registry.tools[name] === descriptor
      assert descriptor.backend == Backplane.AgentRuntime.Codex.Backend
      assert descriptor.tool_revision == 1
      assert descriptor.backend_context.profile == :v2
      invocation = collaboration_invocation(ctx, descriptor)
      assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)
      assert :allow = Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
    end
  end

  test "collaboration exact overrides remain authoritative and unselected restrictions stay known",
       ctx do
    {context, ceiling, native} = collaboration(ctx)
    descriptor = native.registry.tools["spawn_agent"]
    invocation = collaboration_invocation(ctx, descriptor)

    for {decision, expected} <- [deny: {:deny, :policy_denied}, ask: {:deny, :approval_required}] do
      :ok =
        Store.put_value(ctx.identity.session_id, "permission", %{
          ctx.raw
          | tool_overrides: %{"spawn_agent(*)" => decision}
        })

      assert {:ok, %{snapshot: snapshot}} =
               Profiles.build(context, ctx.identity, [native], ceiling)

      assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

      assert Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function)) ==
               expected
    end

    :ok =
      Store.put_value(ctx.identity.session_id, "permission", %{
        ctx.raw
        | tool_overrides: %{"spawn_agent" => :deny}
      })

    assert {:ok, %{snapshot: snapshot}} = build(ctx)
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  test "collaboration cannot exceed parent grants or admitted revisions", ctx do
    {context, ceiling, native} = collaboration(ctx)

    assert {:error, %Error{}} =
             Profiles.build(context, ctx.identity, [native], %{
               ceiling
               | grants: ceiling.grants -- ["spawn_agent"]
             })

    stale = put_in(ceiling, [:tool_revisions, "spawn_agent"], 2)
    assert {:error, %Error{}} = Profiles.build(context, ctx.identity, [native], stale)
    assert native.registry.tools["spawn_agent"].tool_revision == 1
  end

  test "mail and swarm profiles bind configured mailbox and session without child tool expansion",
       ctx do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: "profile-mail-#{ctx.identity.session_id}"})

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent) end)

    :ok =
      Store.put_meta(ctx.identity.session_id, %{id: ctx.identity.session_id, agent: agent.name})

    names = @mail ++ @swarm

    context =
      put_in(ctx.context, [:agent], %{name: agent.name, tool_contract_version: 1, tools: names})

    ceiling = %{ctx.ceiling | grants: names, tool_revisions: Map.new(names, &{&1, 1})}

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, ctx.identity, [], ceiling)

    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(names)
    refute Map.has_key?(bundle.registry.tools, "send_message")
    assert Enum.all?(snapshot.permission_levels, fn {_, level} -> level == :none end)

    for name <- @mail do
      descriptor = bundle.registry.tools[name]
      assert descriptor.backend == Synapsis.Agent.Tools.AgentCommunication
      assert descriptor.backend_context.agent_id == agent.name
      assert descriptor.backend_context.session_id == ctx.identity.session_id
      assert descriptor.backend_context.primary
    end

    for name <- @swarm do
      descriptor = bundle.registry.tools[name]
      assert descriptor.backend == Synapsis.Agent.Tools.Swarm
      assert descriptor.backend_context.sender == agent.name
      assert descriptor.backend_context.session_id == ctx.identity.session_id
    end

    child = Map.put(context, :tool_primary?, false)
    assert {:ok, %{bundle: child_bundle}} = Profiles.build(child, ctx.identity, [], ceiling)
    refute child_bundle.registry.tools["synapsis::agent_ask"].backend_context.primary
  end

  test "mail and swarm exact restrictions stay known when unselected and deny none-level calls",
       ctx do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: "profile-swarm-#{ctx.identity.session_id}"})

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent) end)
    names = ["synapsis::teammate"]

    context =
      put_in(ctx.context, [:agent], %{name: agent.name, tool_contract_version: 1, tools: names})

    ceiling = %{ctx.ceiling | grants: names, tool_revisions: Map.new(names, &{&1, 1})}

    raw = %{
      ctx.raw
      | tool_overrides: %{"synapsis::teammate" => :deny, "synapsis::agent_ask" => :deny}
    }

    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{snapshot: snapshot}} = Profiles.build(context, ctx.identity, [], ceiling)
    assert Map.has_key?(snapshot.known_bindings, "synapsis::agent_ask")
    assert Map.has_key?(snapshot.known_bindings, "synapsis::swarm_message")

    invocation = %{
      ctx.invocation
      | tool_name: "synapsis::teammate",
        arguments: %{"action" => "list"}
    }

    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

    assert {:deny, :policy_denied} =
             Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
  end

  test "presence profiles retain configured owner and exact none-level restrictions", ctx do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: "profile-presence-#{ctx.identity.session_id}"})

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent) end)

    context =
      put_in(ctx.context, [:agent], %{
        name: agent.name,
        tool_contract_version: 1,
        tools: @presence
      })

    ceiling = %{ctx.ceiling | grants: @presence, tool_revisions: Map.new(@presence, &{&1, 1})}
    raw = %{ctx.raw | allow_read: :deny, tool_overrides: %{"synapsis::agent_status" => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, ctx.identity, [], ceiling)

    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(@presence)

    for name <- @presence do
      descriptor = bundle.registry.tools[name]
      assert descriptor.backend == Synapsis.Agent.Tools.SessionPresence
      assert descriptor.backend_context.agent_id == agent.name
      assert descriptor.backend_context.session_id == ctx.identity.session_id
      assert snapshot.permission_levels[name] == :none
    end

    invocation = %{ctx.invocation | tool_name: "synapsis::agent_status", arguments: %{}}
    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

    assert {:deny, :policy_denied} =
             Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))

    invocation = %{
      invocation
      | tool_name: "synapsis::agent_discover",
        arguments: %{"action" => "get", "agent_id" => ctx.identity.session_id}
    }

    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)
    assert :allow = Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
  end

  test "unselected presence restrictions stay known without expanding the catalog", ctx do
    raw = %{ctx.raw | tool_overrides: Map.new(@presence, &{&1, :deny})}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert Enum.all?(@presence, &Map.has_key?(snapshot.known_bindings, &1))
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  test "handoff binds configured sender and exact none-level policy without child grants", ctx do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: "profile-handoff-#{ctx.identity.session_id}"})

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent) end)

    context =
      put_in(ctx.context, [:agent], %{
        name: agent.name,
        tool_contract_version: 1,
        tools: [@handoff]
      })

    context = Map.put(context, :tool_primary?, false)
    ceiling = %{ctx.ceiling | grants: [@handoff], tool_revisions: %{@handoff => 1}}
    raw = %{ctx.raw | allow_read: :deny, allow_write: :deny, tool_overrides: %{@handoff => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, ctx.identity, [], ceiling)

    assert Map.keys(bundle.registry.tools) == [@handoff]
    descriptor = bundle.registry.tools[@handoff]
    assert descriptor.backend == Synapsis.Agent.Tools.AgentHandoff
    assert descriptor.backend_context.agent_id == agent.name
    assert descriptor.backend_context.session_id == ctx.identity.session_id
    refute descriptor.backend_context.agent_id == agent.id
    refute descriptor.backend_context.primary
    assert snapshot.permission_levels[@handoff] == :none

    invocation = %{
      ctx.invocation
      | tool_name: @handoff,
        arguments: %{"to" => "reviewer", "summary" => "Findings", "instructions" => "Review"}
    }

    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

    assert {:deny, :policy_denied} =
             Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
  end

  test "unselected handoff restrictions remain known without admitting handoff", ctx do
    raw = %{ctx.raw | tool_overrides: %{@handoff => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert Map.has_key?(snapshot.known_bindings, @handoff)
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  test "explicit skill retains assigned manual entries and exact none-level restrictions", ctx do
    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: "profile-explicit-#{ctx.identity.session_id}"})

    {:ok, skill} =
      Synapsis.Skills.create(%{
        name: "manual-profile",
        scope: "global",
        system_prompt_fragment:
          "---\nname: manual-profile\ndescription: Review\ndisable-model-invocation: true\n---\nInert review\n"
      })

    {:ok, _} = Synapsis.Skills.assign_skills(agent, [skill.id])

    on_exit(fn ->
      Synapsis.Config.Store.delete(:skill, skill.id)
      Synapsis.AgentConfigs.delete(agent)
    end)

    context =
      put_in(ctx.context, [:agent], %{
        name: agent.name,
        tool_contract_version: 1,
        tools: [@explicit_skill]
      })

    context = Map.put(context, :tool_primary?, false)
    ceiling = %{ctx.ceiling | grants: [@explicit_skill], tool_revisions: %{@explicit_skill => 1}}
    raw = %{ctx.raw | allow_read: :deny, tool_overrides: %{@explicit_skill => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, ctx.identity, [], ceiling)

    assert Map.keys(bundle.registry.tools) == [@explicit_skill]
    descriptor = bundle.registry.tools[@explicit_skill]
    assert descriptor.backend == Synapsis.Agent.Tools.ExplicitSkill
    assert descriptor.backend_context.snapshot.agent_id == agent.id
    assert snapshot.skill_snapshot == descriptor.backend_context.snapshot
    assert snapshot.permission_levels[@explicit_skill] == :none

    assert {:error, :not_found} =
             Synapsis.SkillReader.select(snapshot.skill_snapshot, "synapsis://skills/#{skill.id}")

    invocation = %{
      ctx.invocation
      | tool_name: @explicit_skill,
        arguments: %{"name" => skill.name}
    }

    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

    assert {:deny, :policy_denied} =
             Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
  end

  test "unselected explicit skill restriction is retained without adding read or search", ctx do
    raw = %{ctx.raw | tool_overrides: %{@explicit_skill => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert Map.has_key?(snapshot.known_bindings, @explicit_skill)
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  @tag :agent_directory_production
  test "directory profiles use trusted configured names without loading full agent configs",
       ctx do
    context =
      put_in(ctx.context, [:agent], %{
        name: "profile-directory-requester",
        tool_contract_version: 1,
        tools: [@directory]
      })

    ceiling = %{ctx.ceiling | grants: [@directory], tool_revisions: %{@directory => 1}}
    function = {Synapsis.AgentConfigs, :get_by_name, 1}
    :erlang.trace_pattern(function, true, [:local])
    on_exit(fn -> :erlang.trace_pattern(function, false, [:local]) end)

    task =
      Task.async(fn ->
        receive do
          :build -> Profiles.build(context, ctx.identity, [], ceiling)
        end
      end)

    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :build)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = Task.await(task, 1_000)
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 1_000
    refute_receive {:trace, _, :call, {Synapsis.AgentConfigs, :get_by_name, _}}, 20

    assert Map.keys(bundle.registry.tools) == [@directory]
    descriptor = bundle.registry.tools[@directory]
    assert descriptor.backend == Synapsis.Agent.Tools.AgentDirectory
    assert descriptor.backend_context.requester_name == context.agent.name
    assert descriptor.backend_context.session_id == ctx.identity.session_id
    refute descriptor.backend_context.requester_name == ctx.identity.run_id
    assert snapshot.permission_levels[@directory] == :read
    refute Map.has_key?(bundle.registry.tools, "list_agents")
  end

  @tag :agent_directory_production
  test "directory read level and exact overrides deny through the production policy", ctx do
    context =
      put_in(ctx.context, [:agent], %{
        name: "profile-directory-requester",
        tool_contract_version: 1,
        tools: [@directory]
      })

    ceiling = %{ctx.ceiling | grants: [@directory], tool_revisions: %{@directory => 1}}
    invocation = %{ctx.invocation | tool_name: @directory, arguments: %{}}

    for raw <- [
          %{ctx.raw | allow_read: :deny},
          %{ctx.raw | allow_read: :allow, tool_overrides: %{@directory => :deny}}
        ] do
      :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

      assert {:ok, %{snapshot: snapshot}} =
               Profiles.build(context, ctx.identity, [], ceiling)

      assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

      assert {:deny, :policy_denied} =
               Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
    end
  end

  @tag :agent_directory_production
  test "unselected directory restrictions stay known without expanding selection", ctx do
    raw = %{ctx.raw | tool_overrides: %{@directory => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert Map.has_key?(snapshot.known_bindings, @directory)
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  @tag :automation_production
  test "automation profiles use trusted configured names without loading full agent configs",
       ctx do
    context =
      put_in(ctx.context, [:agent], %{
        name: "profile-automation-requester",
        tool_contract_version: 1,
        tools: ["synapsis::automations"]
      })

    ceiling = %{
      ctx.ceiling
      | grants: ["synapsis::automations"],
        tool_revisions: %{"synapsis::automations" => 1}
    }

    function = {Synapsis.AgentConfigs, :get_by_name, 1}
    :erlang.trace_pattern(function, true, [:local])
    on_exit(fn -> :erlang.trace_pattern(function, false, [:local]) end)

    task =
      Task.async(fn ->
        receive do
          :build -> Profiles.build(context, ctx.identity, [], ceiling)
        end
      end)

    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :build)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = Task.await(task, 1_000)
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 1_000
    refute_receive {:trace, _, :call, {Synapsis.AgentConfigs, :get_by_name, _}}, 20

    assert Map.keys(bundle.registry.tools) == ["synapsis::automations"]
    descriptor = bundle.registry.tools["synapsis::automations"]
    assert descriptor.backend == Synapsis.Agent.Tools.Automations
    assert descriptor.backend_context.requester_name == context.agent.name
    assert descriptor.backend_context.session_id == ctx.identity.session_id
    refute descriptor.backend_context.requester_name == ctx.identity.run_id
    assert snapshot.permission_levels["synapsis::automations"] == :read
    refute Map.has_key?(bundle.registry.tools, "list_agents")
  end

  @tag :automation_production
  test "automation read level and exact overrides deny through the production policy", ctx do
    context =
      put_in(ctx.context, [:agent], %{
        name: "profile-automation-requester",
        tool_contract_version: 1,
        tools: ["synapsis::automations"]
      })

    ceiling = %{
      ctx.ceiling
      | grants: ["synapsis::automations"],
        tool_revisions: %{"synapsis::automations" => 1}
    }

    invocation = %{
      ctx.invocation
      | tool_name: "synapsis::automations",
        arguments: %{"action" => "list"}
    }

    for raw <- [
          %{ctx.raw | allow_read: :deny},
          %{ctx.raw | allow_read: :allow, tool_overrides: %{"synapsis::automations" => :deny}}
        ] do
      :ok = Store.put_value(ctx.identity.session_id, "permission", raw)

      assert {:ok, %{snapshot: snapshot}} =
               Profiles.build(context, ctx.identity, [], ceiling)

      assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)

      assert {:deny, :policy_denied} =
               Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
    end
  end

  @tag :automation_production
  test "unselected automation restrictions stay known without expanding selection", ctx do
    raw = %{ctx.raw | tool_overrides: %{"synapsis::automations" => :deny}}
    :ok = Store.put_value(ctx.identity.session_id, "permission", raw)
    assert {:ok, %{bundle: bundle, snapshot: snapshot}} = build(ctx)
    assert Map.keys(bundle.registry.tools) == [@get]
    assert Map.has_key?(snapshot.known_bindings, "synapsis::automations")
    assert {:ok, _} = Profiles.prepare_context(ctx.invocation, snapshot)
  end

  defp collaboration(ctx) do
    context =
      ctx.context |> put_in([:agent, :tools], @collaboration) |> put_in([:session, :config], %{})

    ceiling = %{
      ctx.ceiling
      | grants: @collaboration,
        tool_revisions: Map.new(@collaboration, &{&1, 1})
    }

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: ctx.identity.run_id,
         parent_name: "/root",
         parent_authority: ceiling,
         child_options: fn _, _, _ -> flunk("policy classification must not spawn a child") end}
      )

    assert {:ok, native} =
             Codex.profile(:collaboration_v2, %{collaboration_runtime: manager}, ceiling,
               tools: @collaboration
             )

    {context, ceiling, native}
  end

  defp collaboration_invocation(ctx, descriptor) do
    arguments =
      case descriptor.tool_name do
        "spawn_agent" ->
          %{"task_name" => "researcher", "message" => "Inspect", "fork_turns" => "none"}

        name when name in ["send_message", "followup_task"] ->
          %{"target" => "researcher", "message" => "Inspect"}

        "interrupt_agent" ->
          %{"target" => "researcher"}

        _ ->
          %{}
      end

    %{
      ctx.invocation
      | tool_name: descriptor.tool_name,
        tool_revision: descriptor.tool_revision,
        arguments: arguments
    }
  end

  defp build(ctx), do: Profiles.build(ctx.context, ctx.identity, [], ctx.ceiling)
end
