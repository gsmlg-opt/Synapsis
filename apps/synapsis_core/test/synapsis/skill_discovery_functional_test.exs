defmodule Synapsis.SkillDiscoveryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.{AgentConfigs, SkillCatalog, SkillDiscovery, SkillReader, Skills, SkillWorkshop}
  alias Synapsis.Config.Store
  alias Synapsis.SkillCatalog.Entry

  @moduletag :tmp_dir
  @document "---\nname: digest-guide\ndescription: Inspect release evidence.\n---\n# Digest guide\n\n1. Read café 雪 😀.\n"
  @alpha_document "---\nname: alpha-guide\ndescription: Record reviewed release results.\n---\n# Alpha guide\n\n1. Save the reviewed result.\n"
  @support "Reviewed release café.\n"
  @changed_support "Reviewed approved release café.\n"
  @raw_files [
    {".draft", <<0, 255, 128, 10>>},
    {".notes/雪.bin", <<1, 0, 254, 240, 159, 152, 128>>},
    {"assets/é.bin", <<9, 8, 7>>},
    {"assets/e\u0301.bin", <<6, 5>>},
    {"assets/雪.bin", <<4, 3, 2, 1>>}
  ]

  # Independent Python hashlib/struct.pack(">Q", length) vectors, frozen before
  # production: prefix b"synapsis-workshop-tree-v1\0", then UTF-8-byte-sorted
  # relative paths and raw content, each preceded by its unsigned 64-bit length.
  @document_digest "sha256:15ccd9ef94874b6276e15f6d66e6bf7af2c5ef10289041a2486184c3f7e24b7b"
  @document_tree "sha256:34d2c93bda4df9d28782d7af5720c8de73e6690be7b00f9aac618d563072040b"
  @complete_tree "sha256:4fed85157f5229ef1e2707478b5294f48b8669c9f58fb5333cf0ab8010d56d4c"
  @support_changed_tree "sha256:60f295b3c4bf00907ac550085429469334e99fd8a77bb8459fc3300b1c962734"
  @main_changed_tree "sha256:7337ede68d74d18400b474e19fe62c0cb54022e05bc92788048ae9fd3a8ee5e2"
  @main_changed_digest "sha256:77de4b21c64021672b2dc41e4b059ec920a0a14ca534b3edbc989020beff9ecc"
  @alpha_digest "sha256:a8a46cbc1ffdce321091f2a7663c62189bbb03b051aadc8c49b66b8378a271a2"
  @alpha_tree "sha256:2ce0ab7732ca15d6e811023de45a6a333579ef1a3356b82d5307dcc512088f0c"

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    previous_entries =
      Map.new([:agent, :skill], fn type ->
        {type, Enum.sort_by(Store.list(type), & &1["id"])}
      end)

    config_dir = Path.join(tmp_dir, "config")
    restore_dir = Path.join(tmp_dir, "restore-config")
    File.mkdir_p!(config_dir)

    on_exit(fn ->
      try do
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
               name: "discovery-main",
               enabled: true,
               config: %{"ordinary_fixture" => "preserve"}
             })

    assert {:ok, assigned} =
             Skills.create(%{
               name: "digest-guide",
               description: "Use the assigned release guide.",
               system_prompt_fragment:
                 "# GLOBAL_ASSIGNED_BODY_ONLY\nRead the assigned release record.\n"
             })

    assert {:ok, agent} = Skills.assign_skills(agent, [assigned.id])
    assert {:ok, scope} = SkillWorkshop.capture(agent.id)
    assert scope.root == Path.join([config_dir, "agents", agent.id, "workshop-skills"])
    refute File.exists?(scope.root)
    assert {:ok, legacy} = SkillReader.snapshot(agent.id)

    %{
      agent: agent,
      assigned: assigned,
      legacy: legacy,
      scope: scope,
      root: scope.root,
      agent_file: File.read!(Store.file_path(:agent)),
      skill_file: File.read!(Store.file_path(:skill)),
      run_id: Ecto.UUID.generate(),
      session_key: "agent:#{agent.id}:discovery"
    }
  end

  test "an absent private root produces an empty learned projection and retains the exact assigned snapshot",
       ctx do
    assert {:ok, %{scope: scope, bindings: []} = projection} =
             SkillWorkshop.catalog_entries(ctx.scope, execution(ctx))

    assert scope === ctx.scope
    assert projection === %{scope: ctx.scope, bindings: []}
    assert {:ok, snapshot} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert_snapshot(snapshot, ctx, [])
    assert snapshot.assigned.assignment_ids == [ctx.assigned.id]
    assert :ok = SkillDiscovery.assigned_current(snapshot)
    refute File.exists?(ctx.root)
    refute File.exists?(Path.dirname(ctx.root))
    assert_preserved(ctx)
    assert File.read!(Store.file_path(:agent)) == ctx.agent_file
  end

  test "two learned entries retain typed source identities, exact metadata and revision-qualified locators beside an assigned namesake",
       ctx do
    create(ctx, "digest-guide", @document)
    create(ctx, "alpha-guide", @alpha_document)
    assert {:ok, snapshot} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    alpha =
      expected_entry(
        ctx,
        "alpha-guide",
        "Record reviewed release results.",
        @alpha_tree,
        @alpha_digest
      )

    digest =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @document_tree,
        @document_digest
      )

    assert_snapshot(snapshot, ctx, [alpha, digest])
    assert {:ok, projection} = SkillWorkshop.catalog_entries(ctx.scope, execution(ctx))
    assert projection === snapshot.learned

    for entry <- [alpha, digest] do
      facts = %{
        name: entry.name,
        description: entry.description,
        revision: entry.revision,
        document_digest: entry.artifact_digest,
        prompt_visible: true
      }

      assert SkillCatalog.from_workshop(ctx.scope, facts) === entry
      assert SkillCatalog.identity(entry) == {:workshop, ctx.agent.id, entry.skill_id}
      assert entry.body == nil
    end

    [assigned_binding] = snapshot.assigned.bindings
    assert SkillDiscovery.binding_key(assigned_binding) == {:assigned, ctx.assigned.id}

    assert SkillCatalog.identity(assigned_binding.entry) ==
             {:synapsis, "synapsis", ctx.assigned.id}

    assert Enum.map(snapshot.learned.bindings, &SkillDiscovery.binding_key/1) == [
             {:workshop, ctx.agent.id, "alpha-guide"},
             {:workshop, ctx.agent.id, "digest-guide"}
           ]

    rendered = SkillCatalog.render(SkillDiscovery.entries(snapshot))

    assert rendered.text ==
             "## Skills\nThe following skills are available. Select a skill when its description matches the task, then use the skill tool with its locator to load the complete SKILL.md. Read referenced resources only as needed.\n\n### Available skills\n" <>
               "- digest-guide: Use the assigned release guide. (locator: synapsis://skills/#{ctx.assigned.id})\n" <>
               "- alpha-guide: Record reviewed release results. (locator: #{alpha.locator})\n" <>
               "- digest-guide: Inspect release evidence. (locator: #{digest.locator})"

    assert rendered.report.total_count == 3
    assert rendered.report.included_count == 3
    assert rendered.report.omitted_count == 0
    refute rendered.text =~ "GLOBAL_ASSIGNED_BODY_ONLY"
    refute rendered.text =~ "1. Read café"
    assert_preserved(ctx)
    assert File.read!(Store.file_path(:agent)) == ctx.agent_file
  end

  test "literal tree revisions cover raw hidden and Unicode support bytes independently of timestamps and empty directories",
       ctx do
    create(ctx, "digest-guide", @document)
    assert {:ok, initial} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert [entry] = SkillDiscovery.entries(initial) -- Enum.map(ctx.legacy.bindings, & &1.entry)
    assert entry.revision == @document_tree
    assert entry.artifact_digest == @document_digest
    assert byte_size(@document) == 106
    assert sha256(@document) == @document_digest

    write_support(ctx, @support)
    write_raw_files(ctx)
    assert {:ok, complete} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    expected =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @complete_tree,
        @document_digest
      )

    assert_snapshot(complete, ctx, [expected])

    files = [{"SKILL.md", @document}, {"references/notes.txt", @support} | @raw_files]

    assert Enum.map(Enum.sort_by(files, &elem(&1, 0)), &elem(&1, 0)) == [
             ".draft",
             ".notes/雪.bin",
             "SKILL.md",
             "assets/e\u0301.bin",
             "assets/é.bin",
             "assets/雪.bin",
             "references/notes.txt"
           ]

    for {relative, bytes} <- files do
      path = Path.join([ctx.root, "digest-guide", relative])
      assert File.read!(path) == bytes
      File.touch!(path, {{2020, 1, 2}, {3, 4, 5}})
    end

    File.mkdir_p!(Path.join([ctx.root, "digest-guide", "assets/empty"]))
    File.mkdir_p!(Path.join([ctx.root, "digest-guide", ".notes/empty"]))
    assert {:ok, same_content} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert same_content === complete
    assert_preserved(ctx)
  end

  test "ordinary support and main edits produce exact new content evidence without invalidating assigned skills",
       ctx do
    create(ctx, "digest-guide", @document)
    write_support(ctx, @support)
    write_raw_files(ctx)
    assert {:ok, before} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    before_entry =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @complete_tree,
        @document_digest
      )

    assert_snapshot(before, ctx, [before_entry])
    frozen = :erlang.term_to_binary(before, [:deterministic])
    assert read_from_new_caller(ctx, before_entry) == read_result(@document, before_entry)

    write_support(ctx, @changed_support)
    assert :ok = SkillDiscovery.assigned_current(before)
    assert {:ok, support_changed} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    support_entry =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @support_changed_tree,
        @document_digest
      )

    assert_snapshot(support_changed, ctx, [support_entry])
    assert support_changed.generation != before.generation
    assert support_entry.artifact_digest == before_entry.artifact_digest
    assert read_from_new_caller(ctx, support_entry) == read_result(@document, support_entry)

    invoke(ctx, %{
      "action" => "patch",
      "name" => "digest-guide",
      "old_text" => "Read café",
      "new_text" => "Review café"
    })

    assert :ok = SkillDiscovery.assigned_current(before)
    assert :ok = SkillDiscovery.assigned_current(support_changed)
    assert {:ok, main_changed} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    main_entry =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @main_changed_tree,
        @main_changed_digest
      )

    assert_snapshot(main_changed, ctx, [main_entry])
    assert main_changed.generation != support_changed.generation
    assert main_entry.artifact_digest != support_entry.artifact_digest
    changed_document = String.replace(@document, "Read café", "Review café")
    assert sha256(changed_document) == @main_changed_digest
    assert read_from_new_caller(ctx, main_entry) == read_result(changed_document, main_entry)
    assert :erlang.term_to_binary(before, [:deterministic]) == frozen
    assert_preserved(ctx)
    assert File.read!(Store.file_path(:agent)) == ctx.agent_file
  end

  test "archive and restore change live membership while prior snapshots and Agent UUID source identity remain stable",
       ctx do
    create(ctx, "digest-guide", @document)
    create(ctx, "alpha-guide", @alpha_document)
    assert {:ok, before} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))

    alpha =
      expected_entry(
        ctx,
        "alpha-guide",
        "Record reviewed release results.",
        @alpha_tree,
        @alpha_digest
      )

    digest =
      expected_entry(
        ctx,
        "digest-guide",
        "Inspect release evidence.",
        @document_tree,
        @document_digest
      )

    assert_snapshot(before, ctx, [alpha, digest])
    frozen = :erlang.term_to_binary(before, [:deterministic])
    invoke(ctx, %{"action" => "archive", "name" => "digest-guide"})
    assert {:ok, archived} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert_snapshot(archived, ctx, [alpha])
    assert archived.generation != before.generation
    assert :ok = SkillDiscovery.assigned_current(before)
    assert read_from_new_caller(ctx, alpha) == read_result(@alpha_document, alpha)
    assert :erlang.term_to_binary(before, [:deterministic]) == frozen

    invoke(ctx, %{"action" => "restore", "name" => "digest-guide"})
    assert {:ok, restored} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert restored === before
    assert read_from_new_caller(ctx, digest) == read_result(@document, digest)

    assert {:ok, renamed} =
             Store.merge_existing(:agent, ctx.agent.id, %{"name" => "renamed-discovery"})

    assert renamed["id"] == ctx.agent.id
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(ctx.agent.id).name == "renamed-discovery"
    assert {:ok, renamed_scope} = SkillWorkshop.capture(ctx.agent.id)
    assert renamed_scope === ctx.scope
    assert {:ok, renamed_snapshot} = SkillDiscovery.capture(ctx.agent.id, execution(ctx))
    assert renamed_snapshot === before
    assert File.ls!(Path.dirname(Path.dirname(ctx.root))) == [ctx.agent.id]
    assert :erlang.term_to_binary(before, [:deterministic]) == frozen
    assert_preserved(ctx)
  end

  defp assert_snapshot(snapshot, ctx, entries) do
    bindings =
      Enum.map(entries, fn entry ->
        %{
          kind: :workshop,
          owner_id: ctx.agent.id,
          entry: entry,
          fingerprint: term_hash({:workshop_binding_v1, ctx.agent.id, entry})
        }
      end)

    learned = %{scope: ctx.scope, bindings: bindings}

    assert snapshot === %{
             schema: 2,
             assigned: ctx.legacy,
             learned: learned,
             generation: "sha256:" <> term_hash({:skill_discovery_v2, ctx.legacy, learned})
           }

    assert SkillDiscovery.valid_snapshot?(snapshot)
    assert SkillReader.valid_snapshot?(snapshot.assigned)
    assert SkillDiscovery.bindings(snapshot) === ctx.legacy.bindings ++ bindings

    assert SkillDiscovery.entries(snapshot) ===
             Enum.map(ctx.legacy.bindings, & &1.entry) ++ entries

    for binding <- snapshot.assigned.bindings do
      assert Enum.sort(Map.keys(binding)) == [:entry, :fingerprint, :record_id]
    end

    for binding <- bindings do
      assert Enum.sort(Map.keys(binding)) == [:entry, :fingerprint, :kind, :owner_id]
    end
  end

  defp expected_entry(ctx, name, description, revision, digest) do
    %Entry{
      authority: :workshop,
      source_id: ctx.agent.id,
      skill_id: name,
      revision: revision,
      artifact_digest: digest,
      name: name,
      description: description,
      locator:
        "workshop://#{ctx.agent.id}/#{URI.encode(name, &URI.char_unreserved?/1)}?revision=#{URI.encode(revision, &URI.char_unreserved?/1)}",
      scope: :agent,
      loader: %{type: :workshop, root: ctx.root},
      body: nil,
      enabled: true,
      prompt_visible: true
    }
  end

  defp assert_preserved(ctx) do
    assert Skills.get(ctx.assigned.id) === ctx.assigned
    assert Skills.list_skill_ids(ctx.agent.id) == [ctx.assigned.id]
    assert AgentConfigs.get(ctx.agent.id).config === ctx.agent.config
    assert File.read!(Store.file_path(:skill)) == ctx.skill_file
    assert {:ok, legacy} = SkillReader.snapshot(ctx.agent.id)
    assert legacy === ctx.legacy
  end

  defp create(ctx, name, content),
    do: invoke(ctx, %{"action" => "create", "name" => name, "content" => content})

  defp write_support(ctx, content),
    do:
      invoke(ctx, %{
        "action" => "write_file",
        "name" => "digest-guide",
        "file_path" => "references/notes.txt",
        "content" => content
      })

  defp write_raw_files(ctx) do
    for {relative, bytes} <- Enum.reverse(@raw_files) do
      path = Path.join([ctx.root, "digest-guide", relative])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end
  end

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

  defp read_from_new_caller(ctx, entry) do
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          with {:ok, scope} <- SkillWorkshop.capture(ctx.agent.id),
               do: SkillWorkshop.read_catalog_entry(scope, entry, execution(ctx))

        send(owner, {:ordinary_catalog_read, self(), result})
      end)

    assert_receive {:ordinary_catalog_read, ^caller, {:ok, result}}, 6_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    refute Process.alive?(caller)
    result
  end

  defp read_result(content, entry),
    do: %{content: content, revision: entry.revision, document_digest: entry.artifact_digest}

  defp execution(ctx),
    do: %{
      deadline: System.monotonic_time(:millisecond) + 5_000,
      session_key: ctx.session_key,
      run_id: ctx.run_id
    }

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp term_hash(term),
    do:
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])),
        case: :lower
      )
end
