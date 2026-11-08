defmodule Synapsis.SkillReaderDiscoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, SkillCatalog, SkillDiscovery, SkillReader, Skills, SkillWorkshop}
  alias Synapsis.Config.Store

  @assigned_document "---\nname: release-guide\ndescription: Review the assigned release record.\n---\n\n1. Read the assigned “café” release record.\n2. Record the quoted result: \"雪 😀\".\n"
  @learned_document "---\nname: release-guide\ndescription: Review the learned release procedure.\n---\n\n1. Read the learned “café” procedure.\n2. Record the quoted result: \"雪 😀\".\n"
  @other_document "---\nname: daily-guide\ndescription: Record the daily review.\n---\n\n1. Collect the review.\n2. Save the result.\n"

  # Ordinary consumer acceptance, frozen independently of reader implementation.
  # Each test owns a fresh partition-qualified root; no ExUnit :tmp_dir is used.
  setup do
    partition = System.fetch_env!("MIX_TEST_PARTITION")
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    previous_entries =
      Map.new([:agent, :skill], fn type ->
        {type, Enum.sort_by(Store.list(type), & &1["id"])}
      end)

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "synapsis-skills348-core-#{URI.encode(partition, &URI.char_unreserved?/1)}-#{Ecto.UUID.generate()}"
      )

    config_dir = Path.join(tmp_root, "config")
    restore_dir = Path.join(tmp_root, "restore-config")
    refute File.exists?(tmp_root)
    refute File.exists?(config_dir)
    refute File.exists?(restore_dir)
    File.mkdir_p!(config_dir)

    on_exit(fn ->
      try do
        refute File.exists?(restore_dir)
        File.mkdir_p!(restore_dir)
        System.put_env("SYNAPSIS_CONFIG_DIR", restore_dir)

        for type <- [:agent, :skill] do
          File.write!(Store.file_path(type), "")
          assert :ok = Store.reload(type)

          for entry <- previous_entries[type] do
            assert {:ok, ^entry} = Store.put(type, entry)
          end

          assert Enum.sort_by(Store.list(type), & &1["id"]) == previous_entries[type]
        end
      after
        if previous,
          do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
          else: System.delete_env("SYNAPSIS_CONFIG_DIR")

        File.rm_rf!(tmp_root)
      end
    end)

    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)

    for type <- [:agent, :skill] do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    assert :ok = Synapsis.Session.Store.ensure_started()

    assert {:ok, agent} =
             AgentConfigs.create(%{
               name: "reader-discovery",
               enabled: true,
               config: %{"skills" => %{"workshop" => %{"maxSkillBytes" => 150_000}}}
             })

    assert {:ok, assigned} =
             Skills.create(%{
               name: "release-guide",
               description: "Review the assigned release record.",
               system_prompt_fragment: @assigned_document
             })

    assert {:ok, agent} = Skills.assign_skills(agent, [assigned.id])
    assert {:ok, legacy} = SkillReader.snapshot(agent.id)
    assert {:ok, scope} = SkillWorkshop.capture(agent.id)
    assert scope.root == Path.join([config_dir, "agents", agent.id, "workshop-skills"])

    %{
      agent: agent,
      assigned: assigned,
      legacy: legacy,
      scope: scope,
      skill_file: File.read!(Store.file_path(:skill)),
      agent_file: File.read!(Store.file_path(:agent)),
      session_key: "agent:#{agent.id}:reader-discovery",
      run_id: Ecto.UUID.generate()
    }
  end

  test "one captured catalog and reader snapshot retain assigned and learned namesakes as distinct typed bindings",
       ctx do
    create(ctx, "release-guide", @learned_document)
    snapshot = capture(ctx)
    assert [assigned, learned] = SkillDiscovery.bindings(snapshot)
    assert SkillDiscovery.binding_key(assigned) == {:assigned, ctx.assigned.id}
    assert SkillDiscovery.binding_key(learned) == {:workshop, ctx.agent.id, "release-guide"}
    assert Enum.sort(Map.keys(assigned)) == [:entry, :fingerprint, :record_id]
    assert Enum.sort(Map.keys(learned)) == [:entry, :fingerprint, :kind, :owner_id]
    assert assigned.entry.name == learned.entry.name
    assert assigned.entry.locator == "synapsis://skills/#{ctx.assigned.id}"

    assert learned.entry.locator ==
             "workshop://#{ctx.agent.id}/release-guide?revision=#{URI.encode(learned.entry.revision, &URI.char_unreserved?/1)}"

    catalog = SkillDiscovery.entries(snapshot)
    assert catalog === [assigned.entry, learned.entry]
    rendered = SkillCatalog.render(catalog)
    assert rendered.report.total_count == 2
    assert rendered.report.included_count == 2

    for binding <- [assigned, learned] do
      assert rendered.text =~ "- release-guide: #{binding.entry.description}"
      assert rendered.text =~ "(locator: #{binding.entry.locator})"
      assert {:ok, selected} = SkillReader.select(snapshot, binding.entry.locator)
      assert selected === binding

      assert {:ok, explicit} =
               SkillReader.select_explicit(snapshot, %{
                 "locator" => binding.entry.locator,
                 "name" => "daily-guide"
               })

      assert explicit === binding
    end

    assert {:ok, %{results: results, truncated: false}} = SkillReader.search(snapshot, "release")

    assert Enum.sort_by(results, & &1.locator) ==
             Enum.sort_by([public(assigned), public(learned)], & &1.locator)

    assert Enum.count(results, &Map.has_key?(&1, :record_id)) == 1
    assert_read(snapshot, assigned, @assigned_document)
    assert_read(snapshot, learned, @learned_document)
    assert_preserved(ctx)
  end

  test "explicit learned selection retains manual metadata and unique-name compatibility", ctx do
    document =
      "---\nname: manual-guide\ndescription: Record a requested review.\ndisable-model-invocation: true\n---\n\n1. Read the requested “café” review.\n2. Save \"雪 😀\" as quoted text.\n"

    create(ctx, "manual-guide", document)
    snapshot = capture(ctx)
    assert [binding] = snapshot.learned.bindings
    assert binding.entry.prompt_visible == false
    assert binding.entry.enabled == true

    assert {:ok, selected} =
             SkillReader.select_explicit(snapshot, %{"name" => "manual-guide"})

    assert selected === binding

    for input <- [%{"name" => "manual-guide"}, %{"locator" => binding.entry.locator}] do
      assert {:ok, page} = SkillReader.read_explicit(snapshot, input)
      assert page === read_result(binding, document)
      assert Map.has_key?(page, :record_id) == false
      assert Jason.decode!(Jason.encode!(page))["content"] == document
    end

    assert_preserved(ctx)
  end

  test "normal long instructional documents remain complete inert assigned and learned content",
       ctx do
    # A normal handbook with many independent numbered steps, within this
    # Agent's approved authoring setting, rather than a maximum-size vector.
    body =
      Enum.map_join(1..650, "\n", fn step ->
        "#{step}. 核对发布记录并记录审阅结论与后续操作；保留“café”、\"雪 😀\"，记录路径 notes\\release。"
      end)

    document =
      "---\nname: release-guide\ndescription: Review the complete release handbook.\n---\n\n# Release handbook\n\n" <>
        body <> "\n\nRecord the complete final review: \"café 雪 😀\".\n"

    assert {:ok, assigned} = Skills.update(ctx.assigned, %{system_prompt_fragment: document})
    assert {:ok, legacy} = SkillReader.snapshot(ctx.agent.id)

    ctx = %{
      ctx
      | assigned: assigned,
        legacy: legacy,
        skill_file: File.read!(Store.file_path(:skill))
    }

    create(ctx, "release-guide", document)
    snapshot = capture(ctx)
    assert [assigned_binding, learned_binding] = SkillDiscovery.bindings(snapshot)

    for binding <- [assigned_binding, learned_binding] do
      page = assert_read(snapshot, binding, document)
      assert Jason.decode!(Jason.encode!(page))["content"] == document

      assert {:ok, explicit} =
               SkillReader.read_explicit(snapshot, %{"locator" => binding.entry.locator})

      assert explicit === page
    end

    assert learned_binding.entry.artifact_digest == digest(document)
    assert assigned_binding.record_id == ctx.assigned.id
    assert_preserved(ctx)
  end

  test "fresh paired readers follow document and support edits, archive and restore with stable source keys",
       ctx do
    create(ctx, "release-guide", @learned_document)
    create(ctx, "daily-guide", @other_document)
    initial = capture(ctx)
    assigned = hd(initial.assigned.bindings)
    learned = learned(initial, "release-guide")
    daily = learned(initial, "daily-guide")
    frozen = :erlang.term_to_binary(initial, [:deterministic])
    assert_read(initial, learned, @learned_document)

    invoke(ctx, %{
      "action" => "patch",
      "name" => "release-guide",
      "old_text" => "Read the learned",
      "new_text" => "Review the learned"
    })

    changed_document = String.replace(@learned_document, "Read the learned", "Review the learned")
    edited = capture(ctx)
    edited_binding = learned(edited, "release-guide")
    assert edited.generation != initial.generation
    assert edited_binding.entry.revision != learned.entry.revision
    assert edited_binding.entry.artifact_digest == digest(changed_document)
    assert edited_binding.entry.artifact_digest != learned.entry.artifact_digest
    assert_read(edited, edited_binding, changed_document)
    assert_read(initial, assigned, @assigned_document)
    assert_read(initial, daily, @other_document)
    assert :ok = SkillDiscovery.assigned_current(initial)

    support = "Reviewed release \"café 雪 😀\".\nRecord the next action.\n"

    invoke(ctx, %{
      "action" => "write_file",
      "name" => "release-guide",
      "file_path" => "references/review.txt",
      "content" => support
    })

    supported = capture(ctx)
    supported_binding = learned(supported, "release-guide")
    assert supported.generation != edited.generation
    assert supported_binding.entry.revision != edited_binding.entry.revision
    assert supported_binding.entry.artifact_digest == edited_binding.entry.artifact_digest

    assert File.read!(Path.join([ctx.scope.root, "release-guide", "references/review.txt"])) ==
             support

    assert_read(supported, supported_binding, changed_document)
    assert_read(initial, assigned, @assigned_document)
    assert_read(initial, daily, @other_document)
    assert :ok = SkillDiscovery.assigned_current(initial)

    invoke(ctx, %{"action" => "archive", "name" => "release-guide"})
    archived = capture(ctx)
    assert SkillDiscovery.bindings(archived) === [assigned, daily]
    assert {:ok, %{results: [result], truncated: false}} = SkillReader.search(archived, "release")
    assert result === public(assigned)
    assert_read(archived, daily, @other_document)

    invoke(ctx, %{"action" => "restore", "name" => "release-guide"})
    restored = capture(ctx)
    assert restored === supported
    restored_binding = learned(restored, "release-guide")
    assert_read(restored, restored_binding, changed_document)

    assert Enum.map([learned, edited_binding, supported_binding, restored_binding], fn binding ->
             SkillDiscovery.binding_key(binding)
           end) == List.duplicate({:workshop, ctx.agent.id, "release-guide"}, 4)

    assert :erlang.term_to_binary(initial, [:deterministic]) == frozen
    assert_preserved(ctx)
  end

  defp capture(ctx) do
    assert {:ok, snapshot} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert snapshot.schema == 2
    assert snapshot.assigned === ctx.legacy
    assert SkillDiscovery.valid_snapshot?(snapshot)
    assert SkillReader.valid_snapshot?(snapshot.assigned)

    assert SkillDiscovery.entries(snapshot) ===
             Enum.map(SkillDiscovery.bindings(snapshot), & &1.entry)

    snapshot
  end

  defp learned(snapshot, name),
    do: Enum.find(snapshot.learned.bindings, &(&1.entry.skill_id == name))

  defp assert_read(snapshot, binding, document) do
    assert {:ok, page} = SkillReader.read(snapshot, binding.entry.locator)
    assert page === read_result(binding, document)
    page
  end

  defp read_result(binding, document),
    do:
      Map.merge(public(binding), %{
        content: document,
        document_digest: digest(document),
        citation: binding.entry.locator
      })

  defp public(%{entry: entry} = binding) do
    fields = %{
      source_authority: Atom.to_string(entry.authority),
      source_id: entry.source_id,
      skill_id: entry.skill_id,
      revision: entry.revision,
      artifact_digest: entry.artifact_digest,
      name: entry.name,
      description: entry.description,
      locator: entry.locator
    }

    case binding do
      %{record_id: id} -> Map.put(fields, :record_id, id)
      %{kind: :workshop} -> fields
    end
  end

  defp assert_preserved(ctx) do
    assert Skills.get(ctx.assigned.id) === ctx.assigned
    assert Skills.list_skill_ids(ctx.agent.id) == [ctx.assigned.id]
    assert File.read!(Store.file_path(:skill)) == ctx.skill_file
    assert File.read!(Store.file_path(:agent)) == ctx.agent_file
    assert {:ok, legacy} = SkillReader.snapshot(ctx.agent.id)
    assert legacy === ctx.legacy
  end

  defp create(ctx, name, document),
    do: invoke(ctx, %{"action" => "create", "name" => name, "content" => document})

  defp invoke(ctx, arguments) do
    assert {:ok, %{"details" => %{"change" => change}} = result} =
             SkillWorkshop.run(ctx.scope, arguments, execution(ctx))

    assert change["agentId"] == ctx.agent.id
    assert change["skillName"] == arguments["name"]
    assert change["action"] == arguments["action"]
    assert change["sessionKey"] == ctx.session_key
    assert change["runId"] == ctx.run_id
    result
  end

  defp execution(ctx),
    do: %{
      deadline: System.monotonic_time(:millisecond) + 5_000,
      session_key: ctx.session_key,
      run_id: ctx.run_id
    }

  defp digest(document),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, document), case: :lower)
end
