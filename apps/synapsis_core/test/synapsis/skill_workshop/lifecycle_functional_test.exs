defmodule Synapsis.SkillWorkshop.LifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, Skills, SkillWorkshop}
  alias Synapsis.Config.Store
  alias Synapsis.SkillWorkshop.Changes

  @moduletag :tmp_dir
  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/skill-workshop.json",
             __DIR__
           )
  @source_rows ~w(list-empty create view-initial write-reference write-template patch-main patch-reference view-reference view-saved remove-reference write-extra restore-explicit view-restored archive list-archived restore-newest list-restored)

  # Independent ordinary success acceptance. Real private files and Concord
  # changes are exercised; native/catalog, source SQL and excluded domains are not.
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
    assert {:ok, agent} = AgentConfigs.create(%{name: "workshop-main", enabled: true})
    assert {:ok, scope} = SkillWorkshop.capture(agent.id)
    root = Path.join([config_dir, "agents", agent.id, "workshop-skills"])
    refute File.exists?(root)
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "skill_workshop:#{agent.id}")

    %{
      agent: agent,
      scope: scope,
      root: root,
      config_dir: config_dir,
      run_id: Ecto.UUID.generate(),
      session_key: "agent:#{agent.id}:source",
      node: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    }
  end

  test "all seventeen pinned calls retain exact source envelopes, whole trees and durable changes",
       ctx do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == @reference
    assert Enum.map(fixture["observations"], & &1["id"]) == @source_rows

    initial = %{change_symbols: %{}, version_symbols: %{}, changes: [], newest_version_time: 0}

    state =
      Enum.reduce(fixture["observations"], initial, fn row, state ->
        args = actual_arguments(row["argumentsBefore"], state)
        started = System.system_time(:millisecond)
        result = invoke(ctx, args)
        ended = System.system_time(:millisecond)
        state = register_reference_result(state, result, row["result"], started, ended)
        assert_list_facts(result, ctx)
        assert normalize(result, state) == row["result"], row["id"]
        assert normalize(file_tree(ctx.root), state) == row["tree"], row["id"]
        state
      end)

    assert length(state.changes) == 10
    assert map_size(state.version_symbols) == 8
    assert {:ok, persisted} = Changes.list(ctx.agent.id, [run_id: ctx.run_id], deadline())
    assert persisted == Enum.reverse(state.changes)
    assert normalize(Enum.reverse(persisted), state) == fixture["changeLedger"]

    reopened =
      fresh_invoke(ctx, %{
        "action" => "view",
        "name" => "deploy-guide",
        "file_path" => "references/notes.md"
      })

    assert reopened ==
             Enum.find(fixture["observations"], &(&1["id"] == "view-restored"))["result"]

    assert {:ok, ^persisted} = Changes.list(ctx.agent.id, [run_id: ctx.run_id], deadline())
  end

  test "sibling guidance and absorbed archive leave the broad procedure and global assignment intact",
       ctx do
    assert {:ok, assigned} =
             Skills.create(%{
               name: "assigned-guide",
               description: "Existing assigned skill.",
               system_prompt_fragment: "# Assigned\nRead the release record.\n"
             })

    assert {:ok, agent} = Skills.assign_skills(ctx.agent, [assigned.id])
    assert {:ok, scope} = SkillWorkshop.capture(agent.id)
    ctx = %{ctx | agent: agent, scope: scope}
    skill_config = File.read!(Store.file_path(:skill))
    broad = markdown("deploy-broad", "Deploy reviewed releases.")
    narrow = markdown("deploy-narrow", "Record one release result.")

    created = invoke(ctx, %{"action" => "create", "name" => "deploy-broad", "content" => broad})

    assert_mutation(
      created,
      "Created",
      "deploy-broad",
      "created: Deploy reviewed releases.",
      false
    )

    broad_tree = file_tree(Path.join(ctx.root, "deploy-broad"), "")

    created = invoke(ctx, %{"action" => "create", "name" => "deploy-narrow", "content" => narrow})

    assert created["content"] == [
             %{
               "type" => "text",
               "text" =>
                 "Created \"deploy-narrow\" (created: Record one release result.). Undo with action=archive name=deploy-narrow.\nOther learned skills; if one covers the same class of task, merge (patch the broader one, archive the other with absorbed_into):\n- deploy-broad: Deploy reviewed releases."
             }
           ]

    archived =
      invoke(ctx, %{
        "action" => "archive",
        "name" => "deploy-narrow",
        "absorbed_into" => "deploy-broad",
        "reason" => "retain one shared procedure"
      })

    assert_mutation(
      archived,
      "Archived",
      "deploy-narrow",
      "archived: merged into deploy-broad; retain one shared procedure",
      true
    )

    assert file_tree(Path.join(ctx.root, "deploy-broad"), "") == broad_tree
    assert Skills.get(assigned.id) == assigned
    assert Skills.list_skill_ids(agent.id) == [assigned.id]
    assert File.read!(Store.file_path(:skill)) == skill_config
    assert File.read!(Path.join([ctx.root, "deploy-broad", "SKILL.md"])) == broad
  end

  test "Agent rename and ordinary reopening retain the private UUID root and archived version lineage",
       ctx do
    first =
      markdown(
        "release-notes",
        "Record reviewed releases.",
        "1. Read the review.\n2. Record the result."
      )

    second =
      markdown(
        "release-notes",
        "Record approved release results.",
        "1. Read the approval.\n2. Save the result."
      )

    invoke(ctx, %{"action" => "create", "name" => "release-notes", "content" => first})

    invoke(ctx, %{
      "action" => "write_file",
      "name" => "release-notes",
      "file_path" => "examples/result.txt",
      "content" => "Reviewed release café.\n"
    })

    archived = invoke(ctx, %{"action" => "archive", "name" => "release-notes"})
    assert_mutation(archived, "Archived", "release-notes", "archived", true)
    lineage = file_tree(Path.join([ctx.root, ".archive", "release-notes"]), "")
    assert length(File.ls!(Path.join([ctx.root, ".archive", "release-notes"]))) == 2

    recreated =
      invoke(ctx, %{"action" => "create", "name" => "release-notes", "content" => second})

    assert_mutation(
      recreated,
      "Created",
      "release-notes",
      "created: Record approved release results.",
      false
    )

    assert file_tree(Path.join([ctx.root, ".archive", "release-notes"]), "") == lineage
    assert file_tree(Path.join(ctx.root, "release-notes"), "") == [file_fact("SKILL.md", second)]

    assert {:ok, renamed} =
             Store.merge_existing(:agent, ctx.agent.id, %{"name" => "renamed-workshop"})

    assert renamed["id"] == ctx.agent.id
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(ctx.agent.id).name == "renamed-workshop"
    assert {:ok, _fresh_scope} = SkillWorkshop.capture(ctx.agent.id)

    assert fresh_invoke(ctx, %{"action" => "view", "name" => "release-notes"}) ==
             text_result(second, %{
               "name" => "release-notes",
               "filePath" => "SKILL.md",
               "files" => ["SKILL.md"]
             })

    assert File.read!(Path.join([ctx.root, "release-notes", "SKILL.md"])) == second
    assert File.ls!(Path.join(ctx.config_dir, "agents")) == [ctx.agent.id]
    assert {:ok, changes} = Changes.list(ctx.agent.id, [run_id: ctx.run_id], deadline())
    assert Enum.map(changes, & &1["action"]) == ["create", "archive", "write_file", "create"]
  end

  test "live default restore is undoable and explicit restore snapshots the current complete tree",
       ctx do
    first =
      markdown("release-undo", "Inspect reviewed releases.", "1. Inspect the reviewed release.")

    second =
      markdown("release-undo", "Inspect approved releases.", "1. Inspect the approved release.")

    invoke(ctx, %{"action" => "create", "name" => "release-undo", "content" => first})

    written =
      invoke(ctx, %{
        "action" => "write_file",
        "name" => "release-undo",
        "file_path" => "SKILL.md",
        "content" => second
      })

    assert_mutation(written, "Updated", "release-undo", "rewrote SKILL.md", true)
    first_version = written["details"]["change"]["versionId"]

    restored = invoke(ctx, %{"action" => "restore", "name" => "release-undo"})
    assert_mutation(restored, "Restored", "release-undo", "undid write file", true)
    saved_second = restored["details"]["change"]["versionId"]
    assert File.read!(Path.join([ctx.root, "release-undo", "SKILL.md"])) == first

    assert File.read!(Path.join([ctx.root, ".archive", "release-undo", saved_second, "SKILL.md"])) ==
             second

    undo_restore = invoke(ctx, %{"action" => "restore", "name" => "release-undo"})
    assert_mutation(undo_restore, "Restored", "release-undo", "undid restore", true)
    assert File.read!(Path.join([ctx.root, "release-undo", "SKILL.md"])) == second

    explicit =
      invoke(ctx, %{"action" => "restore", "name" => "release-undo", "version" => first_version})

    assert_mutation(
      explicit,
      "Restored",
      "release-undo",
      "restored version #{first_version}",
      true
    )

    prior_live = explicit["details"]["change"]["versionId"]
    assert prior_live != first_version

    assert File.read!(Path.join([ctx.root, ".archive", "release-undo", prior_live, "SKILL.md"])) ==
             second

    assert File.read!(Path.join([ctx.root, "release-undo", "SKILL.md"])) == first
    assert length(File.ls!(Path.join([ctx.root, ".archive", "release-undo"]))) == 4
  end

  test "exact patches retain literal replacement bytes and omitted new_text removes its exact text",
       ctx do
    initial =
      markdown(
        "literal-patch",
        "Record reviewed releases.",
        "1. Record the result.\n2. Remove marker TOKEN."
      )

    invoke(ctx, %{"action" => "create", "name" => "literal-patch", "content" => initial})

    literal =
      invoke(ctx, %{
        "action" => "patch",
        "name" => "literal-patch",
        "old_text" => "Record the result.",
        "new_text" => "$& $1 $$ café 雪 😀"
      })

    assert_mutation(literal, "Patched", "literal-patch", "patched SKILL.md", true)

    removed =
      invoke(ctx, %{"action" => "patch", "name" => "literal-patch", "old_text" => "TOKEN"})

    assert_mutation(removed, "Patched", "literal-patch", "patched SKILL.md", true)

    expected =
      markdown(
        "literal-patch",
        "Record reviewed releases.",
        "1. $& $1 $$ café 雪 😀\n2. Remove marker ."
      )

    assert invoke(ctx, %{"action" => "view", "name" => "literal-patch"}) ==
             text_result(expected, %{
               "name" => "literal-patch",
               "filePath" => "SKILL.md",
               "files" => ["SKILL.md"]
             })

    assert File.read!(Path.join([ctx.root, "literal-patch", "SKILL.md"])) == expected
  end

  test "introduced-only authoring advice accompanies committed mutations without rewriting their bytes",
       ctx do
    initial =
      markdown("authoring-notes", "This skill is powerful.", "1. Record the release result.")

    created =
      invoke(ctx, %{"action" => "create", "name" => "authoring-notes", "content" => initial})

    assert created["content"] == [
             %{
               "type" => "text",
               "text" =>
                 "Created \"authoring-notes\" (created: This skill is powerful.). Undo with action=archive name=authoring-notes.\nAdvisory (not blocking): description opens with \"This skill\"; open with the situation that triggers it. Fix with action=patch.\nAdvisory (not blocking): cut no-op emphasis (powerful); plain steps carry the same weight. Fix with action=patch."
             }
           ]

    assert File.read!(Path.join([ctx.root, "authoring-notes", "SKILL.md"])) == initial

    revised =
      markdown(
        "authoring-notes",
        "This skill remains robust.",
        "1. Record the reviewed result.\nUPDATE: Fold the new step into the procedure."
      )

    written =
      invoke(ctx, %{
        "action" => "write_file",
        "name" => "authoring-notes",
        "file_path" => "SKILL.md",
        "content" => revised
      })

    assert written["content"] == [
             %{
               "type" => "text",
               "text" =>
                 "Updated \"authoring-notes\" (rewrote SKILL.md). Saved previous version; undo with action=restore name=authoring-notes.\nAdvisory (not blocking): found an update note or date; fold the lesson into the step it changes. Fix with action=patch."
             }
           ]

    assert File.read!(Path.join([ctx.root, "authoring-notes", "SKILL.md"])) == revised
  end

  test "snapshots retain hidden files and empty directories while restore publishes the visible validated tree",
       ctx do
    initial = markdown("snapshot-shapes", "Inspect reviewed release records.")
    reference = "Reviewed reference café 雪 😀.\n"
    invoke(ctx, %{"action" => "create", "name" => "snapshot-shapes", "content" => initial})

    invoke(ctx, %{
      "action" => "write_file",
      "name" => "snapshot-shapes",
      "file_path" => "references/notes.md",
      "content" => reference
    })

    live = Path.join(ctx.root, "snapshot-shapes")
    File.mkdir_p!(Path.join(live, ".notes"))
    File.mkdir_p!(Path.join(live, "assets/empty"))
    File.write!(Path.join(live, ".draft"), "Draft note.\n")
    File.write!(Path.join(live, ".notes/plan.txt"), "Private authoring scratch.\n")
    File.write!(Path.join(live, "references/.scratch"), "Reference scratch.\n")
    before = file_tree(live, "")

    listed = invoke(ctx, %{"action" => "list"})

    assert [%{"name" => "snapshot-shapes", "files" => ["SKILL.md", "references/notes.md"]}] =
             listed["details"]["skills"]

    assert_list_facts(listed, ctx)

    patched =
      invoke(ctx, %{
        "action" => "patch",
        "name" => "snapshot-shapes",
        "old_text" => "Inspect the release.",
        "new_text" => "Inspect the reviewed release."
      })

    saved = patched["details"]["change"]["versionId"]
    saved_root = Path.join([ctx.root, ".archive", "snapshot-shapes", saved])
    assert file_tree(saved_root, "") == before
    assert File.dir?(Path.join(saved_root, "assets/empty"))
    assert File.ls!(Path.join(saved_root, "assets/empty")) == []

    restored =
      invoke(ctx, %{"action" => "restore", "name" => "snapshot-shapes", "version" => saved})

    assert_mutation(restored, "Restored", "snapshot-shapes", "restored version #{saved}", true)

    assert file_tree(live, "") ==
             Enum.sort_by(
               [file_fact("SKILL.md", initial), file_fact("references/notes.md", reference)],
               & &1["path"]
             )

    assert File.ls!(live) |> Enum.sort() == ["SKILL.md", "references"]
    final = invoke(ctx, %{"action" => "list"})
    assert_list_facts(final, ctx)
    assert [%{"files" => ["SKILL.md", "references/notes.md"]}] = final["details"]["skills"]
  end

  defp invoke(ctx, args) do
    started = System.system_time(:millisecond)
    assert {:ok, result} = SkillWorkshop.run(ctx.scope, args, execution(ctx))
    assert_committed_result(ctx, args, result, started, System.system_time(:millisecond))
    result
  end

  defp fresh_invoke(ctx, args) do
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        started = System.system_time(:millisecond)

        result =
          with {:ok, scope} <- SkillWorkshop.capture(ctx.agent.id),
               do: SkillWorkshop.run(scope, args, execution(ctx))

        send(
          owner,
          {:ordinary_workshop_reopen, self(), result, started, System.system_time(:millisecond)}
        )
      end)

    assert_receive {:ordinary_workshop_reopen, ^caller, {:ok, result}, started, ended}, 6_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    refute Process.alive?(caller)
    assert_committed_result(ctx, args, result, started, ended)
    result
  end

  defp assert_committed_result(ctx, args, result, started, ended) do
    if change = result["details"]["change"] do
      assert {:ok, id} = Ecto.UUID.cast(change["id"])
      assert id == change["id"]

      assert Regex.match?(
               ~r/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,
               id
             )

      assert change["agentId"] == ctx.agent.id
      assert change["skillName"] == args["name"]
      assert change["action"] == args["action"]
      assert change["actor"] == "agent"
      assert change["sessionKey"] == ctx.session_key
      assert change["runId"] == ctx.run_id
      assert is_integer(change["createdAtMs"])
      assert change["createdAtMs"] >= started and change["createdAtMs"] <= ended
      assert_receive {:skill_workshop_changed, ^change}, 1_000
      assert {:ok, [^change | _]} = Changes.list(ctx.agent.id, [run_id: ctx.run_id], deadline())

      if version = change["versionId"] do
        {_time, action} = version_facts(version)
        assert action == args["action"]
        assert File.dir?(Path.join([ctx.root, ".archive", args["name"], version]))
      end
    end
  end

  defp execution(ctx),
    do: %{deadline: deadline(), session_key: ctx.session_key, run_id: ctx.run_id}

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp actual_arguments(args, state) do
    if version = args["version"] do
      {actual, ^version} =
        Enum.find(state.version_symbols, fn {_actual, symbol} -> symbol == version end)

      Map.put(args, "version", actual)
    else
      args
    end
  end

  defp register_reference_result(state, result, expected, started, ended) do
    if change = result["details"]["change"] do
      source = expected["details"]["change"]
      refute Map.has_key?(state.change_symbols, change["id"])

      state = %{
        state
        | change_symbols: Map.put(state.change_symbols, change["id"], source["id"]),
          changes: state.changes ++ [change]
      }

      if version = change["versionId"] do
        {time, action} = version_facts(version)
        assert action == change["action"]
        assert time > state.newest_version_time
        assert time >= started and time <= max(ended, state.newest_version_time + 1)
        refute Map.has_key?(state.version_symbols, version)

        %{
          state
          | version_symbols: Map.put(state.version_symbols, version, source["versionId"]),
            newest_version_time: time
        }
      else
        state
      end
    else
      state
    end
  end

  defp normalize(value, state) when is_list(value), do: Enum.map(value, &normalize(&1, state))

  defp normalize(%{"skillName" => _, "agentId" => _, "id" => id} = change, state) do
    symbol = Map.fetch!(state.change_symbols, id)

    change
    |> Map.put("id", symbol)
    |> Map.put("agentId", "agent292")
    |> Map.put("sessionKey", "agent:agent292:source")
    |> Map.put("runId", "run292")
    |> Map.put("createdAtMs", symbol <> "::time")
    |> Map.new(fn {key, value} -> {key, normalize(value, state)} end)
  end

  defp normalize(%{"id" => id, "action" => action, "createdAtMs" => created} = version, state) do
    {actual_time, ^action} = version_facts(id)
    assert created == actual_time
    symbol = Map.fetch!(state.version_symbols, id)
    version |> Map.put("id", symbol) |> Map.put("createdAtMs", symbol <> "::time")
  end

  defp normalize(%{} = value, state) do
    value
    |> Map.new(fn {key, item} -> {key, normalize(item, state)} end)
    |> then(fn result ->
      if Map.has_key?(result, "updatedAtMs"),
        do: Map.put(result, "updatedAtMs", "$LIVE_TREE_MTIME"),
        else: result
    end)
  end

  defp normalize(value, state) when is_binary(value) do
    Enum.reduce(state.version_symbols, value, fn {actual, symbol}, text ->
      String.replace(text, actual, symbol)
    end)
  end

  defp normalize(value, _state), do: value

  defp version_facts(id) do
    assert [year, month, day, hour, minute, second, millisecond, action] =
             Regex.run(
               ~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3})Z-(create|patch|write_file|remove_file|archive|restore)$/,
               id,
               capture: :all_but_first
             )

    assert {:ok, datetime, 0} =
             DateTime.from_iso8601(
               "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{millisecond}Z"
             )

    {DateTime.to_unix(datetime, :millisecond), action}
  end

  defp assert_list_facts(result, ctx) do
    for skill <- result["details"]["skills"] || [] do
      actual = precise_stat_oracle(ctx.node, Path.join(ctx.root, skill["name"]), skill["files"])
      assert skill["sizeBytes"] == actual["sizeBytes"]
      assert skill["updatedAtMs"] == actual["updatedAtMs"]
    end

    for archived <- result["details"]["archived"] || [], version <- archived["versions"] do
      {time, action} = version_facts(version["id"])
      assert version["createdAtMs"] == time
      assert version["action"] == action
    end
  end

  # Independent test-owned builtin stats, not the production metadata helper.
  defp precise_stat_oracle(node, root, files) do
    script =
      "const fs=require('node:fs'),path=require('node:path');const s=JSON.parse(process.argv[2]).map(p=>fs.statSync(path.join(process.argv[1],p)));process.stdout.write(JSON.stringify({sizeBytes:s.reduce((n,v)=>n+v.size,0),updatedAtMs:Math.trunc(Math.max(0,...s.map(v=>v.mtimeMs)))}));"

    port =
      Port.open({:spawn_executable, String.to_charlist(node)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["-e", script, root, Jason.encode!(files)]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    bytes = oracle_bytes(port, [], deadline())
    assert Port.info(port) == nil
    refute File.exists?("/proc/#{os_pid}")
    Jason.decode!(bytes)
  end

  defp oracle_bytes(port, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} -> oracle_bytes(port, [chunk | bytes], deadline)
      {^port, {:exit_status, 0}} -> bytes |> Enum.reverse() |> IO.iodata_to_binary()
    after
      max(1, deadline - System.monotonic_time(:millisecond)) ->
        if Port.info(port), do: Port.close(port)
        flunk("ordinary independent stat capture did not complete")
    end
  end

  defp file_tree(root, prefix \\ "workshop-skills") do
    if File.dir?(root), do: walk_files(root, prefix) |> Enum.sort_by(& &1["path"]), else: []
  end

  defp walk_files(root, prefix) do
    Enum.flat_map(File.ls!(root), fn name ->
      absolute = Path.join(root, name)
      path = if prefix == "", do: name, else: prefix <> "/" <> name

      case File.lstat!(absolute).type do
        :directory -> walk_files(absolute, path)
        :regular -> [file_fact(path, File.read!(absolute))]
      end
    end)
  end

  defp file_fact(path, content),
    do: %{
      "path" => path,
      "content" => content,
      "bytes" => byte_size(content),
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }

  defp assert_mutation(result, verb, name, summary, saved?) do
    change = result["details"]["change"]
    assert change["summary"] == summary
    assert Map.has_key?(change, "versionId") == saved?

    undo =
      if saved?,
        do: "Saved previous version; undo with action=restore name=#{name}.",
        else: "Undo with action=archive name=#{name}."

    assert result ==
             text_result("#{verb} \"#{name}\" (#{summary}). #{undo}", %{"change" => change})
  end

  defp markdown(name, description, body \\ "1. Inspect the release.\n2. Record the result."),
    do: "---\nname: #{name}\ndescription: #{description}\n---\n\n#{body}\n"

  defp text_result(text, details),
    do: %{"content" => [%{"type" => "text", "text" => text}], "details" => details}
end
