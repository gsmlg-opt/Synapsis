defmodule Synapsis.Agent.Tools.SkillsTest do
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
  alias Synapsis.Agent.Tools.{ResultProjection, Skills}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Config.Store

  @search "synapsis::skills_search"
  @read "synapsis::skills_read"

  defmodule RecordingBackend do
    def execute(operation) do
      send(operation.backend_context.test_pid, :skills_dispatched)
      Skills.execute(operation)
    end
  end

  setup do
    {:ok, agent} =
      AgentConfigs.create(%{name: "native-skills-tools-#{System.unique_integer([:positive])}"})

    {:ok, record} =
      Synapsis.Skills.create(%{
        name: "review",
        scope: "global",
        description: "Review changes",
        system_prompt_fragment: "Inert instructions"
      })

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
      context: %{snapshot: snapshot, run_id: "run-a", incarnation: 1, catalog_revision: 1}
    }
  end

  test "strict descriptors admit native bindings with exact grants and closed schemas", ctx do
    assert {:ok, [search, read] = descriptors} = Skills.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == [@search, @read]

    for descriptor <- descriptors do
      assert descriptor.backend == Skills
      assert descriptor.backend_context === ctx.context
      assert descriptor.tool_revision === 2
      assert descriptor.schema["additionalProperties"] == false
      assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    end

    assert Enum.sort(Map.keys(search.schema["properties"])) == ["limit", "query"]
    assert Map.keys(read.schema["properties"]) == ["locator"]
    assert {:ok, _} = InputSchema.validate(read.schema, %{"locator" => ctx.locator})

    assert {:error, %Error{}} =
             InputSchema.validate(read.schema, %{"locator" => ctx.locator, "root" => "/"})

    assert {:ok, %{accepted: [@search, @read]}} =
             ToolCatalog.admit_batch(descriptors, authority: authority())

    for changed <- [
          %{authority() | grants: ["*"]},
          %{authority() | grants: []},
          %{authority() | tool_revisions: %{@search => 2, @read => 3}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch(descriptors, authority: changed)
    end
  end

  test "permission classification binds assigned agent and exact persisted source record", ctx do
    assert {:ok, %{action: "skill.read", resource: resource}} =
             Skills.classify(ctx.context, operation(ctx, @read, %{"locator" => ctx.locator}))

    assert resource ==
             "skill:agent:#{ctx.agent.id}:source:synapsis:synapsis:record:#{ctx.record.id}"

    assert {:ok, %{action: "skill.read", resource: "skill:agent:" <> _}} =
             Skills.classify(ctx.context, operation(ctx, @search, %{"query" => "review"}))

    assert {:error, :not_found} =
             Skills.classify(
               ctx.context,
               operation(ctx, @read, %{"locator" => "synapsis://skills/foreign"})
             )
  end

  test "search publishes metadata and read publishes inert text plus citation", ctx do
    assert {:ok, %{content: text, structured: %{results: [hit]}}} =
             Skills.execute(operation(ctx, @search, %{"query" => "review"}))

    assert hit.record_id == ctx.record.id
    assert text =~ ctx.locator
    refute text =~ "Inert instructions"

    assert {:ok, %{content: read_text, structured: page}} =
             Skills.execute(operation(ctx, @read, %{"locator" => ctx.locator}))

    assert page.content == "Inert instructions"
    assert read_text =~ page.content
    assert read_text =~ ctx.locator
    assert page.citation == ctx.locator
  end

  test "automatic search and read source evidence survives the safe public projection", ctx do
    for {name, arguments} <- [
          {@search, %{"query" => "review"}},
          {@read, %{"locator" => ctx.locator}}
        ] do
      assert {:ok, result} = Skills.execute(operation(ctx, name, arguments))
      assert {:ok, part} = ResultProjection.to_part("auto-skill-call", result, tool_name: name)
      assert {:ok, projection} = ResultProjection.from_part(part)
      assert projection === part.projection
      structured = projection["result"]["structured"]

      public =
        case name do
          @search ->
            assert [hit] = structured["results"]
            refute Map.has_key?(hit, "content")
            hit

          @read ->
            assert structured["content"] == "Inert instructions"
            assert structured["citation"] == ctx.locator
            structured
        end

      assert public["source_authority"] == "synapsis"
      assert public["record_id"] == ctx.record.id
      assert public["source_id"] == "synapsis"
      assert public["locator"] == ctx.locator
      refute Map.has_key?(public, "authority")
      refute Map.has_key?(public, "loader")
      refute Map.has_key?(public, "fingerprint")
    end
  end

  test "model authority overrides, malformed input and exact scope mismatches fail closed", ctx do
    op = operation(ctx, @search, %{"query" => "review"})

    for key <- ["root", "agent_id", "source", "credentials", "path", "record_id"] do
      assert {:error, %Error{class: :validation}} =
               Skills.execute(%{op | arguments: Map.put(op.arguments, key, "foreign")})
    end

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 1.0
        ] do
      changed = Map.put(op, key, value)
      assert {:error, :scope_mismatch} = Skills.classify(ctx.context, changed)
      assert {:error, %Error{class: :forbidden}} = Skills.execute(changed)
    end

    changed = put_in(op, [:backend_context, :snapshot, :agent_id], Ecto.UUID.generate())
    assert {:error, :scope_mismatch} = Skills.classify(ctx.context, changed)
    assert {:error, %Error{class: :validation}} = Skills.execute(nil)
    assert :ok = Skills.cancel(op)
  end

  test "malformed trusted contexts and invalid search limits never become descriptors or reads",
       ctx do
    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :agent_id, "foreign"),
          %{ctx.context | run_id: ""},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0},
          put_in(ctx.context, [:snapshot, :agent_id], "")
        ] do
      assert {:error, %Error{class: :validation}} = Skills.descriptors(context)
    end

    for arguments <- [
          %{},
          %{"query" => ""},
          %{"query" => <<255>>},
          %{"query" => String.duplicate("q", 2049)},
          %{"query" => "review", "limit" => 0},
          %{"query" => "review", "limit" => 21},
          %{"query" => "review", "limit" => 1.0}
        ] do
      assert {:error, %Error{class: :validation}} =
               Skills.execute(operation(ctx, @search, arguments))
    end
  end

  test "live reassignment rejects the old backend context", ctx do
    {:ok, _} = Synapsis.Skills.assign_skills(ctx.agent, [])

    assert {:error, %Error{class: :forbidden, details: %{code: "stale_snapshot"}}} =
             Skills.execute(operation(ctx, @read, %{"locator" => ctx.locator}))
  end

  test "provider credential identity, routing and disablement changes reject before loader",
       ctx do
    {:ok, first} = Synapsis.Credentials.create(%{name: "native-skill-first", key: "first"})
    {:ok, second} = Synapsis.Credentials.create(%{name: "native-skill-second", key: "second"})
    provider_id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    provider = %{
      "id" => provider_id,
      "enabled" => true,
      "type" => "openai",
      "base_url" => "http://127.0.0.1:9/v1",
      "credential_id" => first.id
    }

    {:ok, _} = Store.put(:provider, provider)

    {:ok, _} =
      Store.put(:backplane, %{"id" => source_id, "enabled" => true, "provider_id" => provider_id})

    {:ok, remote} =
      Synapsis.Skills.create(%{
        scope: "global",
        name: "native-provider-review",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "review",
          "external_revision" => "rev-7"
        }
      })

    {:ok, _} = Synapsis.Skills.assign_skills(ctx.agent, [remote.id])
    previous_loader = Application.get_env(:synapsis_core, :skill_loader)
    owner = self()

    Application.put_env(:synapsis_core, :skill_loader, fn _, _ ->
      send(owner, :provider_loader_called)
      {:error, :unexpected_load}
    end)

    on_exit(fn ->
      if previous_loader,
        do: Application.put_env(:synapsis_core, :skill_loader, previous_loader),
        else: Application.delete_env(:synapsis_core, :skill_loader)

      Store.delete(:skill, remote.id)
      Store.delete(:backplane, source_id)
      Store.delete(:provider, provider_id)
      Synapsis.Credentials.delete(first.id)
      Synapsis.Credentials.delete(second.id)
    end)

    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    {:ok, %{results: [hit]}} = SkillReader.search(snapshot, "native-provider")
    fresh = put_in(ctx, [:context, :snapshot], snapshot)

    for changed <- [
          Map.put(provider, "credential_id", second.id),
          Map.put(provider, "base_url", "http://127.0.0.1:10/v1"),
          Map.put(provider, "enabled", false)
        ] do
      {:ok, _} = Store.put(:provider, changed)

      assert {:error, %Error{class: :forbidden, details: %{code: "stale_snapshot"}}} =
               Skills.execute(operation(fresh, @read, %{"locator" => hit.locator}))

      refute_receive :provider_loader_called
    end
  end

  test "actual native Execution reads skills and revoked grants create no dispatch or intent",
       ctx do
    {:ok, descriptors} = Skills.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority())
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})

    record = %{
      run_id: "run-a",
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
      operation(ctx, @read, %{"locator" => ctx.locator})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority(),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    assert {:ok, _, %{effects: [%{structured: %{content: "Inert instructions"}}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    spy =
      Enum.map(
        descriptors,
        &%{
          &1
          | backend: RecordingBackend,
            backend_context: Map.put(&1.backend_context, :test_pid, self())
        }
      )

    {:ok, spy_bundle} = ToolCatalog.admit_batch(spy, authority: authority())
    {:ok, denied_table} = EphemeralStore.new(1)

    denied =
      options
      |> Keyword.put(:registry, spy_bundle.registry)
      |> Keyword.put(:authority, %{authority() | grants: []})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               denied_table,
               record,
               %{command: {:tool_invoked, 11, input}},
               denied
             )

    assert :ets.tab2list(denied_table) == []
    refute_receive :skills_dispatched
  end

  test "native hierarchical run identities remain opaque while scope matching stays exact", ctx do
    for run_id <- ["/root/researcher:1", "/root/研究者/child:2"] do
      child = put_in(ctx, [:context, :run_id], run_id)
      assert {:ok, _} = Skills.descriptors(child.context)
      op = %{operation(child, @read, %{"locator" => ctx.locator}) | run_id: run_id}
      assert {:ok, _} = Skills.classify(child.context, op)
      assert {:ok, _} = Skills.execute(op)
      assert {:error, :scope_mismatch} = Skills.classify(child.context, %{op | run_id: "other"})
      assert {:error, %Error{class: :forbidden}} = Skills.execute(%{op | run_id: "other"})
    end

    for run_id <- [nil, 0, "", " ", <<255>>, "child\0run", String.duplicate("r", 4097)] do
      child = put_in(ctx, [:context, :run_id], run_id)
      assert {:error, %Error{class: :validation}} = Skills.descriptors(child.context)

      assert {:error, %Error{class: :validation}} =
               Skills.execute(operation(child, @read, %{"locator" => ctx.locator}))
    end
  end

  test "native Conversation executes both descriptors with runtime-enriched child context", ctx do
    run_id = "/root/researcher:1"
    ctx = put_in(ctx, [:context, :run_id], run_id)
    {:ok, descriptors} = Skills.descriptors(ctx.context)

    {:ok, bundle} =
      ToolCatalog.admit_batch(descriptors,
        mode: :strict,
        authority: Map.put(authority(), :run_id, run_id)
      )

    script = fn request ->
      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 ->
          [Proof.call(@search, %{"query" => "review"}), Proof.completed("Searching")]

        1 ->
          [
            put_in(
              Proof.call(@read, %{"locator" => ctx.locator}),
              [:tool_call, :id],
              "read-call"
            ),
            Proof.completed("Reading")
          ]

        _ ->
          [Proof.completed("Done")]
      end
    end

    options =
      Proof.options(run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        work: 10
      )

    pid = start_supervised!({Conversation, options})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Read native resources")
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
    assert [search, read] = Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))
    refute Map.get(search.result, :is_error, false)
    refute Map.get(read.result, :is_error, false)
    assert [%{record_id: id}] = search.result.structured.results
    assert id == ctx.record.id
    assert read.result.structured.content == "Inert instructions"
  end

  test "only documented runtime additions are ignored by execute; trusted classification stays strict",
       ctx do
    base = operation(ctx, @read, %{"locator" => ctx.locator})

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> :unused end,
        append_feedback: fn _ -> :unused end,
        emit: fn _ -> :unused end,
        stage_catalog: fn _ -> :unused end,
        request_new_context: fn -> :unused end,
        nested_dispatch: fn _ -> :unused end,
        resource_owner_pid: self()
      })

    assert {:ok, _} = Skills.execute(%{base | backend_context: enriched})
    assert {:error, %Error{class: :validation}} = Skills.descriptors(enriched)

    assert {:error, :invalid_context} =
             Skills.classify(enriched, %{base | backend_context: enriched})

    invalid = Map.put(enriched, :project_id, "foreign")

    assert {:error, %Error{class: :validation}} =
             Skills.execute(%{base | backend_context: invalid})
  end

  defp authority,
    do: %{
      caller: "caller",
      run_id: "run-a",
      grants: [@search, @read],
      tool_revisions: %{@search => 2, @read => 2}
    }

  defp operation(ctx, name, args),
    do: %{
      tool_name: name,
      tool_revision: 2,
      arguments: args,
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context
    }
end
