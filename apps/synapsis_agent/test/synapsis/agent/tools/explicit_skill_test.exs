defmodule Synapsis.Agent.Tools.ExplicitSkillTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog
  }

  alias Synapsis.{AgentConfigs, SkillReader}
  alias Synapsis.Agent.Tools.{ExplicitSkill, ResultProjection, Skills}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Config.Store

  @name "synapsis::skill"

  defmodule RecordingBackend do
    def execute(operation) do
      send(operation.backend_context.test_pid, :explicit_skill_dispatched)
      {:ok, %{content: "Unexpected dispatch"}}
    end
  end

  setup do
    assert Code.ensure_loaded?(ExplicitSkill),
           "the explicit native skill adapter is not implemented"

    {:ok, agent} = AgentConfigs.create(%{name: "explicit-native-#{Ecto.UUID.generate()}"})

    body =
      "---\nname: manual\ndescription: Manual review\ndisable-model-invocation: true\n---\nInert instructions\n"

    {:ok, record} =
      Synapsis.Skills.create(%{name: "manual", scope: "global", system_prompt_fragment: body})

    {:ok, _} = Synapsis.Skills.assign_skills(agent, [record.id])

    on_exit(fn ->
      Store.delete(:agent, agent.id)
      Store.delete(:skill, record.id)
    end)

    {:ok, snapshot} = SkillReader.snapshot(agent.id)

    %{
      agent: agent,
      record: record,
      locator: "synapsis://skills/#{record.id}",
      context: %{snapshot: snapshot, run_id: "/root/研究者:1", incarnation: 1, catalog_revision: 1}
    }
  end

  test "one exact native capability retains legacy fields and permission level", ctx do
    assert ExplicitSkill.names() == [@name]
    assert ExplicitSkill.permission_level(@name) == :none
    assert {:ok, [descriptor]} = ExplicitSkill.descriptors(ctx.context)
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision === 2
    assert descriptor.backend == ExplicitSkill
    assert descriptor.backend_context === ctx.context
    assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    assert descriptor.schema["additionalProperties"] == false
    assert Enum.sort(Map.keys(descriptor.schema["properties"])) == ["locator", "name"]

    for args <- [
          %{"locator" => ctx.locator},
          %{"name" => "manual"},
          %{"locator" => ctx.locator, "name" => "other"},
          %{"locator" => "", "name" => "manual"}
        ] do
      assert {:ok, ^args} = InputSchema.validate(descriptor.schema, args)
    end

    for args <- [%{}, %{"name" => 1}, %{"locator" => ctx.locator, "root" => "/"}] do
      assert {:error, %Error{class: :validation}} = InputSchema.validate(descriptor.schema, args)
    end

    assert {:ok, _} = ToolCatalog.admit_batch([descriptor], authority: authority(ctx))

    for changed <- [
          %{authority(ctx) | grants: []},
          %{authority(ctx) | grants: ["*"]},
          %{authority(ctx) | grants: ["skill"]},
          %{authority(ctx) | tool_revisions: %{@name => 3}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch([descriptor], authority: changed)
    end
  end

  test "manual explicit read classifies the exact assignment without broadening auto tools",
       ctx do
    assert {:ok, %{action: "skill.read", resource: resource}} =
             ExplicitSkill.classify(ctx.context, operation(ctx, %{"name" => "manual"}))

    assert resource ==
             "skill:agent:#{ctx.agent.id}:source:synapsis:synapsis:record:#{ctx.record.id}"

    assert {:ok, result} = ExplicitSkill.execute(operation(ctx, %{"locator" => ctx.locator}))
    assert result.structured.content == ctx.record.system_prompt_fragment
    assert result.structured.citation == ctx.locator
    assert result.structured.record_id == ctx.record.id
    assert result.content =~ "Inert instructions"
    assert {:ok, by_name} = ExplicitSkill.execute(operation(ctx, %{"name" => "manual"}))
    assert by_name.structured === result.structured

    assert {:error, %Error{class: :not_found}} =
             Skills.execute(%{
               operation(ctx, %{"locator" => ctx.locator})
               | tool_name: "synapsis::skills_read"
             })

    assert {:ok, %{results: []}} = SkillReader.search(ctx.context.snapshot, "manual")
  end

  test "legacy locator precedence stays exact and does not fall back from an unknown locator",
       ctx do
    assert {:ok, result} =
             ExplicitSkill.execute(
               operation(ctx, %{
                 "locator" => ctx.locator,
                 "name" => "unassigned-name"
               })
             )

    assert result.structured.record_id == ctx.record.id

    assert {:ok, _} =
             ExplicitSkill.execute(operation(ctx, %{"locator" => "", "name" => "manual"}))

    assert {:error, %Error{class: :not_found}} =
             ExplicitSkill.execute(
               operation(ctx, %{
                 "locator" => "synapsis://skills/unassigned",
                 "name" => "manual"
               })
             )

    {:ok, duplicate} = Synapsis.Skills.create(%{name: "manual", scope: "global"})
    on_exit(fn -> Store.delete(:skill, duplicate.id) end)
    {:ok, _} = Synapsis.Skills.assign_skills(ctx.agent, [ctx.record.id, duplicate.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    fresh = put_in(ctx, [:context, :snapshot], snapshot)

    assert {:error, %Error{class: :validation, details: %{code: "ambiguous"}}} =
             ExplicitSkill.execute(operation(fresh, %{"name" => "manual"}))

    assert {:ok, _} = ExplicitSkill.execute(operation(fresh, %{"locator" => ctx.locator}))
  end

  test "trusted context and native run incarnation catalog and tool revision are closed", ctx do
    base = operation(ctx, %{"locator" => ctx.locator})

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 1.0
        ] do
      changed = Map.put(base, key, value)
      assert {:error, :scope_mismatch} = ExplicitSkill.classify(ctx.context, changed)
      assert {:error, %Error{class: :forbidden}} = ExplicitSkill.execute(changed)
    end

    changed = put_in(base, [:backend_context, :snapshot, :agent_id], Ecto.UUID.generate())
    assert {:error, :scope_mismatch} = ExplicitSkill.classify(ctx.context, changed)
    assert {:error, %Error{class: :validation}} = ExplicitSkill.execute(nil)

    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :root, "/"),
          %{ctx.context | run_id: ""},
          %{ctx.context | run_id: <<255>>},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0}
        ] do
      assert {:error, %Error{class: :validation}} = ExplicitSkill.descriptors(context)
    end

    for key <- ["agent_id", "path", "root", "sender", "source", "credentials", "record_id"] do
      assert {:error, %Error{class: :validation}} =
               ExplicitSkill.execute(%{base | arguments: Map.put(base.arguments, key, "foreign")})
    end

    assert :ok = ExplicitSkill.cancel(base)
  end

  test "only documented runtime context additions are accepted during native execution", ctx do
    base = operation(ctx, %{"locator" => ctx.locator})

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> :unused end,
        append_feedback: fn _ -> :unused end,
        emit: fn _ -> :unused end,
        stage_catalog: fn _ -> :unused end,
        request_new_context: fn -> :unused end,
        nested_dispatch: fn _ -> :unused end,
        resource_owner_pid: self(),
        goal: nil,
        goal_binding: nil
      })

    assert {:ok, _} = ExplicitSkill.execute(%{base | backend_context: enriched})
    assert {:error, %Error{class: :validation}} = ExplicitSkill.descriptors(enriched)

    assert {:error, :invalid_context} =
             ExplicitSkill.classify(enriched, %{base | backend_context: enriched})

    assert {:error, %Error{class: :validation}} =
             ExplicitSkill.execute(%{base | backend_context: Map.put(enriched, :sender, "other")})
  end

  test "revoked assignment and disabled records reject frozen context", ctx do
    input = operation(ctx, %{"locator" => ctx.locator})
    {:ok, _} = Synapsis.Skills.assign_skills(ctx.agent, [])

    assert {:error, %Error{class: :forbidden, details: %{code: "stale_snapshot"}}} =
             ExplicitSkill.execute(input)

    {:ok, _} = Synapsis.Skills.assign_skills(ctx.agent, [ctx.record.id])
    {:ok, _} = Synapsis.Skills.update(ctx.record, %{enabled: false})
    assert {:error, %Error{class: :forbidden}} = ExplicitSkill.execute(input)
    {:ok, empty} = SkillReader.snapshot(ctx.agent.id)
    fresh = put_in(ctx, [:context, :snapshot], empty)

    assert {:error, %Error{class: :not_found}} =
             ExplicitSkill.execute(operation(fresh, %{"locator" => ctx.locator}))
  end

  test "public result projection retains source evidence and no backend bindings", ctx do
    assert {:ok, result} = ExplicitSkill.execute(operation(ctx, %{"name" => "manual"}))
    assert {:ok, part} = ResultProjection.to_part("explicit-call", result, tool_name: @name)
    assert {:ok, projection} = ResultProjection.from_part(part)
    assert projection === part.projection
    public = part.projection["result"]["structured"]
    assert public["source_authority"] == "synapsis"
    refute Map.has_key?(public, "authority")
    assert public["record_id"] == ctx.record.id
    assert public["citation"] == ctx.locator
    assert public["revision"] == nil
    assert public["artifact_digest"] == nil
    assert public["document_digest"] =~ "sha256:"
    assert public["content"] == ctx.record.system_prompt_fragment
    encoded = Jason.encode!(part.projection)

    for private <- [
          "backend_context",
          "fingerprint",
          "assignment_ids",
          "loader",
          "config_overrides"
        ] do
      refute encoded =~ private
    end
  end

  test "actual native Execution reads manual content and denies wrong grants without intent",
       ctx do
    {:ok, descriptors} = ExplicitSkill.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 4})

    record = %{
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

    input =
      operation(ctx, %{"locator" => ctx.locator})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority(ctx),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    assert {:ok, _, %{effects: [%{structured: %{record_id: id}}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    assert id == ctx.record.id

    spy =
      Enum.map(
        descriptors,
        &%{
          &1
          | backend: RecordingBackend,
            backend_context: Map.put(&1.backend_context, :test_pid, self())
        }
      )

    {:ok, spy_bundle} = ToolCatalog.admit_batch(spy, authority: authority(ctx))

    for grants <- [[], ["skill"], ["synapsis::skills_read"]] do
      {:ok, denied_table} = EphemeralStore.new(1)

      denied =
        options
        |> Keyword.put(:registry, spy_bundle.registry)
        |> Keyword.put(:authority, %{authority(ctx) | grants: grants})

      assert {:error, %Error{class: :forbidden}} =
               Execution.run(
                 EphemeralStore,
                 denied_table,
                 record,
                 %{command: {:tool_invoked, 11, input}},
                 denied
               )

      assert :ets.tab2list(denied_table) == []
      refute_receive :explicit_skill_dispatched
    end
  end

  test "native Conversation executes the explicit skill with enriched opaque child scope", ctx do
    {:ok, descriptors} = ExplicitSkill.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("Done")],
        else: [Proof.call(@name, %{"name" => "manual"}), Proof.completed("Reading")]
    end

    options =
      Proof.options(ctx.context.run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        work: 5
      )

    pid = start_supervised!({Conversation, options})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Read the assigned manual skill")
    run_id = ctx.context.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
    assert [read] = Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))
    refute Map.get(read.result, :is_error, false)
    assert read.result.structured.content == ctx.record.system_prompt_fragment
  end

  defp authority(ctx),
    do: %{
      caller: "caller",
      run_id: ctx.context.run_id,
      grants: [@name],
      tool_revisions: %{@name => 2}
    }

  defp operation(ctx, arguments),
    do: %{
      tool_name: @name,
      tool_revision: 2,
      arguments: arguments,
      run_id: ctx.context.run_id,
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context
    }
end
