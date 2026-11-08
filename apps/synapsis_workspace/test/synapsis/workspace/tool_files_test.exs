defmodule Synapsis.Workspace.ToolFilesTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workspace.{FileDocuments, ToolFiles}

  @moduletag :tmp_dir
  @session "11111111-1111-4111-8111-111111111111"

  setup %{tmp_dir: root} do
    assert Code.ensure_loaded?(ToolFiles), "bounded Workspace tool domain is not implemented"
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a")
    %{root: root, identity: %{role: :session, agent_id: "agent-a", session_id: @session}}
  end

  test "session scope reads shared and own agent paths but mutates only its own session", ctx do
    shared = "/shared/notes/a.md"
    own_agent = "/agents/agent-a/notes/a.md"
    own = own_path("a.md")
    foreign = "/agents/agent-b/notes/a.md"
    for path <- [shared, own_agent, own, foreign], do: fixture(ctx, path, "original")

    for path <- [shared, own_agent, own] do
      assert {:ok, %{content: "original"}} =
               ToolFiles.perform(ctx.identity, :file_read, %{"path" => path})
    end

    for path <- [shared, own_agent, foreign] do
      assert {:error, :permission_denied} =
               ToolFiles.perform(ctx.identity, :file_write, %{
                 "path" => path,
                 "content" => "denied"
               })

      assert File.read!(physical(ctx, path)) == "original"
    end

    assert {:error, :permission_denied} =
             ToolFiles.perform(ctx.identity, :file_read, %{"path" => foreign})

    refute_receive {:workspace_changed, _}, 0

    assert {:ok, %{status: "updated", path: ^own}} =
             ToolFiles.perform(ctx.identity, :file_write, %{
               "path" => own,
               "content" => "persisted"
             })

    assert_receive {:workspace_changed, %{path: ^own, action: :updated}}
    assert File.read!(physical(ctx, own)) == "persisted"
    assert {:ok, document} = FileDocuments.get(ctx.root, own)
    assert document.updated_by == "agent-a"
    assert document.session_id == @session
  end

  test "bounded read uses real line pages and preserves virtual domain identities", ctx do
    path = own_path("read.md")
    fixture(ctx, path, "one\ntwo\nthree\n")

    assert {:ok, %{path: ^path, content: "two\n", offset: 1, next_offset: 2, truncated: true}} =
             ToolFiles.perform(ctx.identity, :file_read, %{
               "path" => path,
               "offset" => 1,
               "limit" => 1
             })

    fixture(ctx, own_path("long.md"), String.duplicate("界", 30_000))

    assert {:ok, page} =
             ToolFiles.perform(ctx.identity, :file_read, %{"path" => own_path("long.md")})

    assert page.partial_line and page.truncated and page.next_offset == nil
    assert byte_size(page.content) <= 32_768 and String.valid?(page.content)
  end

  test "write edit delete and move preserve metadata and publish after persistence", ctx do
    source = own_path("source.md")
    target = own_path("nested/target.md")

    assert {:ok, %{status: "created"}} =
             ToolFiles.perform(ctx.identity, :file_write, %{
               "path" => source,
               "content" => "one one"
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :created}}

    assert {:ok, %{status: "updated"}} =
             ToolFiles.perform(ctx.identity, :file_edit, %{
               "path" => source,
               "old_string" => "one",
               "new_string" => "two"
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :updated}}
    assert File.read!(physical(ctx, source)) == "two one"

    assert {:ok, %{status: "moved", source: ^source, destination: ^target}} =
             ToolFiles.perform(ctx.identity, :file_move, %{
               "source" => source,
               "destination" => target
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :deleted}}
    assert_receive {:workspace_changed, %{path: ^target, action: :created}}
    refute File.exists?(physical(ctx, source))
    assert File.read!(physical(ctx, target)) == "two one"
    assert {:error, :not_found} = FileDocuments.get(ctx.root, source)
    assert {:ok, document} = FileDocuments.get(ctx.root, target)
    assert document.agent_id == "agent-a" and document.session_id == @session

    assert {:ok, %{status: "deleted"}} =
             ToolFiles.perform(ctx.identity, :file_delete, %{"path" => target})

    assert_receive {:workspace_changed, %{path: ^target, action: :deleted}}
    refute File.exists?(physical(ctx, target))
    assert {:error, :not_found} = FileDocuments.get(ctx.root, target)
  end

  test "no-op and conflict never publish a successful change", ctx do
    path = own_path("no-op.md")
    fixture(ctx, path, "same")

    assert {:ok, %{status: "unchanged"}} =
             ToolFiles.perform(ctx.identity, :file_write, %{"path" => path, "content" => "same"})

    assert {:ok, %{status: "unchanged"}} =
             ToolFiles.perform(ctx.identity, :file_edit, %{
               "path" => path,
               "old_string" => "same",
               "new_string" => "same"
             })

    assert {:error, :conflict} =
             ToolFiles.perform(ctx.identity, :file_edit, %{
               "path" => path,
               "old_string" => "absent",
               "new_string" => "bad"
             })

    assert File.read!(physical(ctx, path)) == "same"
    refute_receive {:workspace_changed, _}, 0
  end

  test "every multi-edit and move target is authorized before any write", ctx do
    path = own_path("allowed.md")
    fixture(ctx, path, "one")

    edits = [
      %{"path" => path, "old_string" => "one", "new_string" => "two"},
      %{"path" => "/shared/denied.md", "old_string" => "a", "new_string" => "b"}
    ]

    assert {:error, :permission_denied} =
             ToolFiles.perform(ctx.identity, :multi_edit, %{"edits" => edits})

    assert {:error, :permission_denied} =
             ToolFiles.perform(ctx.identity, :file_move, %{
               "source" => path,
               "destination" => "/agents/other/b.md"
             })

    assert File.read!(physical(ctx, path)) == "one"
    refute_receive {:workspace_changed, _}, 0
  end

  test "list glob and regex search page only permitted logical documents", ctx do
    prefix = own_path("notes")

    for {path, content} <- [
          {prefix <> "/a.md", "needle one\nneedle two\n"},
          {prefix <> "/b.txt", "needle ignored"},
          {"/agents/other/private.md", "needle secret"}
        ] do
      fixture(ctx, path, content)
    end

    assert {:ok, %{entries: [%{path: first}], next_offset: 1, truncated: true}} =
             ToolFiles.perform(ctx.identity, :list_dir, %{
               "path" => prefix,
               "depth" => 1,
               "limit" => 1
             })

    assert first == prefix <> "/a.md"

    assert {:ok, %{paths: [matched]}} =
             ToolFiles.perform(ctx.identity, :glob, %{"path" => prefix, "pattern" => "*.md"})

    assert matched == prefix <> "/a.md"

    assert {:ok,
            %{
              matches: [%{path: match, line: 1, text: "needle one"}],
              next_offset: 1,
              truncated: true
            }} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix,
               "pattern" => "needle (one|two)",
               "include" => "*.md",
               "limit" => 1
             })

    assert match == prefix <> "/a.md"

    assert {:ok, %{matches: [%{line: 2}], next_offset: nil, truncated: false}} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix,
               "pattern" => "needle (one|two)",
               "include" => "*.md",
               "offset" => 1,
               "limit" => 1
             })
  end

  test "traversal and physical symlinks cannot escape the Workspace domain", ctx do
    outside = ctx.root <> "-outside"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.md"), "secret")
    on_exit(fn -> File.rm_rf!(outside) end)
    own_dir = physical(ctx, own_path("link"))
    File.mkdir_p!(Path.dirname(own_dir))
    File.ln_s!(outside, own_dir)

    assert {:error, :unsafe_path} =
             ToolFiles.perform(ctx.identity, :file_read, %{"path" => own_path("link/secret.md")})

    assert {:error, :unsafe_path} =
             ToolFiles.perform(ctx.identity, :file_write, %{
               "path" => own_path("link/new.md"),
               "content" => "bad"
             })

    assert {:error, :unsafe_path} =
             ToolFiles.perform(ctx.identity, :file_read, %{"path" => own_path("../secret.md")})

    assert File.read!(Path.join(outside, "secret.md")) == "secret"
    refute File.exists?(Path.join(outside, "new.md"))
    refute_receive {:workspace_changed, _}, 0
  end

  test "domain-backed writes stay rejected instead of shadowing skills memory or todos", ctx do
    for path <- [
          "/agents/agent-a/memory/fact.md",
          "/agents/agent-a/skills/test.md",
          "/agents/agent-a/sessions/#{@session}/todo.md"
        ] do
      assert {:error, :domain_path} =
               ToolFiles.perform(%{ctx.identity | role: :agent}, :file_write, %{
                 "path" => path,
                 "content" => "shadow"
               })

      refute File.exists?(physical(ctx, path))
    end

    refute_receive {:workspace_changed, _}, 0
  end

  test "projected skills merge with ordinary files before list and glob pagination", ctx do
    {skill, other} = projected_skills()
    prefix = "/shared/skills/#{skill.name}"
    projected = prefix <> "/SKILL.md"
    ordinary = prefix <> "/a.md"
    fixture(ctx, ordinary, "ordinary file")

    assert {:ok, %{entries: [%{path: ^projected}], truncated: true, next_offset: 1}} =
             ToolFiles.perform(ctx.identity, :list_dir, %{"path" => prefix, "limit" => 1})

    assert {:ok, %{entries: [%{path: ^ordinary}], truncated: false, next_offset: nil}} =
             ToolFiles.perform(ctx.identity, :list_dir, %{
               "path" => prefix,
               "offset" => 1,
               "limit" => 1
             })

    assert {:ok, %{paths: paths}} =
             ToolFiles.perform(ctx.identity, :glob, %{"path" => prefix, "pattern" => "*.md"})

    assert paths == [projected, ordinary]
    refute Enum.any?(paths, &String.contains?(&1, other.name))

    assert {:ok, %{content: content}} =
             ToolFiles.perform(ctx.identity, :file_read, %{"path" => projected})

    assert content =~ "projected needle"
  end

  test "regex search includes projected skill content and applies exact requested prefix", ctx do
    {skill, other} = projected_skills()
    prefix = "/shared/skills/#{skill.name}"
    fixture(ctx, prefix <> "/ordinary.md", "ordinary needle")

    assert {:ok, %{matches: matches}} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix,
               "pattern" => "(?:projected|ordinary) needle",
               "include" => "*.md"
             })

    assert Enum.map(matches, & &1.path) |> Enum.uniq() == [
             prefix <> "/SKILL.md",
             prefix <> "/ordinary.md"
           ]

    assert Enum.any?(matches, &(&1.text =~ "projected needle"))
    refute Enum.any?(matches, &String.contains?(&1.path, other.name))

    assert {:ok, %{entries: []}} =
             ToolFiles.perform(ctx.identity, :list_dir, %{"path" => prefix <> "/absent"})
  end

  test "merged search reads beyond a read page and retains projected path priority", ctx do
    {skill, _other} = projected_skills()
    prefix = "/shared/skills/#{skill.name}"
    projected = prefix <> "/SKILL.md"
    ordinary = prefix <> "/ordinary.md"
    fixture(ctx, projected, "shadow needle")
    fixture(ctx, ordinary, String.duplicate("x", 40_000) <> "\nlate needle\n")

    assert {:ok, %{matches: [%{path: ^ordinary, line: 2, text: "late needle"}]}} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix,
               "pattern" => "(?:shadow|late) needle"
             })

    assert {:ok, %{matches: [%{path: ^projected} | _]}} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix,
               "pattern" => "projected needle"
             })

    assert {:error, :invalid_pattern} =
             ToolFiles.perform(ctx.identity, :grep, %{
               "path" => prefix <> "/absent",
               "pattern" => "["
             })
  end

  test "merged pagination retains more than one ordinary page", ctx do
    {skill, _other} = projected_skills()
    prefix = "/shared/skills/#{skill.name}"

    for index <- 0..200 do
      fixture(ctx, prefix <> "/file-#{String.pad_leading(to_string(index), 3, "0")}.md", "body")
    end

    assert {:ok, %{entries: [%{path: last}], truncated: false, next_offset: nil}} =
             ToolFiles.perform(ctx.identity, :list_dir, %{
               "path" => prefix,
               "offset" => 201,
               "limit" => 1
             })

    assert last == prefix <> "/file-200.md"
  end

  defp projected_skills do
    suffix = System.unique_integer([:positive])

    assert {:ok, skill} =
             Synapsis.Skills.create(%{
               name: "fs-projection-#{suffix}",
               description: "projected needle",
               system_prompt_fragment: "projected needle body"
             })

    assert {:ok, other} =
             Synapsis.Skills.create(%{
               name: "fs-unrelated-#{suffix}",
               description: "projected needle",
               system_prompt_fragment: "unrelated secret"
             })

    on_exit(fn ->
      Synapsis.Skills.delete(skill)
      Synapsis.Skills.delete(other)
    end)

    {skill, other}
  end

  test "interrupted batches persist and publish metadata for known completed files", ctx do
    first = own_path("a.txt")
    second = own_path("b.txt")
    fixture(ctx, first, "x")
    fixture(ctx, second, "x")
    {:ok, previous} = FileDocuments.get(ctx.root, first)
    Process.flag(:priority, :high)
    owner = self()
    second_file = physical(ctx, second)

    caller =
      spawn(fn ->
        receive do
          :go ->
            edits =
              for path <- [first, second],
                  do: %{"path" => path, "old_string" => "x", "new_string" => "y"}

            send(
              owner,
              {:tool_files_finished,
               ToolFiles.perform(ctx.identity, :multi_edit, %{"edits" => edits})}
            )
        end
      end)

    :erlang.trace_pattern({File, :open, 2}, true, [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.exit(caller, :kill)
    end)

    send(caller, :go)
    assert_receive {:trace, worker, :call, {File, :open, [^second_file, _]}}, 1_000
    :erlang.suspend_process(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert File.read!(physical(ctx, first)) == "y"
    assert File.read!(second_file) == "x"
    Process.exit(worker, :kill)

    assert_receive {:tool_files_finished, {:error, {:unknown_outcome, evidence}}}, 2_000
    assert Enum.any?(evidence.files, &(&1.path == first and &1.status == "updated"))
    assert Enum.any?(evidence.files, &(&1.path == second and &1.status == "unknown_outcome"))
    assert {:ok, document} = FileDocuments.get(ctx.root, first)
    assert document.version == previous.version + 1
    assert_receive {:workspace_changed, %{path: ^first, action: :updated}}
    refute_receive {:workspace_changed, %{path: ^second}}, 0
  end

  test "metadata failure retains completed changes and finalizes later batch files", ctx do
    [first, second, third, conflict, unchanged] =
      Enum.map(~w(a.txt b.txt c.txt d.txt e.txt), &own_path/1)

    for path <- [first, second, third, conflict, unchanged], do: fixture(ctx, path, "x")
    second_meta = metadata_path(ctx, second)
    previous_meta = File.read!(second_meta)
    File.chmod!(second_meta, 0o444)
    on_exit(fn -> File.chmod(second_meta, 0o644) end)

    edits =
      Enum.map([first, second, third], fn path ->
        %{"path" => path, "old_string" => "x", "new_string" => "y"}
      end) ++
        [
          %{"path" => conflict, "old_string" => "absent", "new_string" => "y"},
          %{"path" => unchanged, "old_string" => "x", "new_string" => "x"}
        ]

    assert {:error, {:unknown_outcome, evidence}} =
             ToolFiles.perform(ctx.identity, :multi_edit, %{"edits" => edits})

    assert evidence.status == "partial"
    assert evidence.reason == "metadata_persistence"

    assert Enum.map(evidence.files, &{&1.path, &1.status}) == [
             {first, "updated"},
             {second, "updated"},
             {third, "updated"},
             {conflict, "conflict"},
             {unchanged, "unchanged"}
           ]

    assert Enum.filter(evidence.files, &(Map.get(&1, :metadata_status) == "unconfirmed")) == [
             %{path: second, status: "updated", bytes: 1, metadata_status: "unconfirmed"}
           ]

    for path <- [first, second, third], do: assert(File.read!(physical(ctx, path)) == "y")
    for path <- [conflict, unchanged], do: assert(File.read!(physical(ctx, path)) == "x")
    assert File.read!(second_meta) == previous_meta

    for path <- [first, third] do
      assert {:ok, document} = FileDocuments.get(ctx.root, path)
      assert document.version == 2
      assert_receive {:workspace_changed, %{path: ^path, action: :updated}}
    end

    refute_receive {:workspace_changed, _}, 0
  end

  test "move publishes persisted destination metadata when source metadata deletion fails", ctx do
    source = own_path("source.txt")
    destination = own_path("destination.txt")
    fixture(ctx, source, "source body")
    fixture(ctx, destination, "old destination")
    source_meta = metadata_path(ctx, source)
    previous_meta = File.read!(source_meta)
    meta_dir = Path.dirname(source_meta)
    File.chmod!(meta_dir, 0o555)
    on_exit(fn -> File.chmod(meta_dir, 0o755) end)

    assert {:error, {:unknown_outcome, evidence}} =
             ToolFiles.perform(ctx.identity, :file_move, %{
               "source" => source,
               "destination" => destination
             })

    assert evidence.status == "moved"
    assert evidence.source == source
    assert evidence.destination == destination
    assert evidence.reason == "metadata_persistence"
    assert evidence.metadata_status == %{source: "unconfirmed", destination: "persisted"}
    refute File.exists?(physical(ctx, source))
    assert File.read!(physical(ctx, destination)) == "source body"
    assert File.read!(source_meta) == previous_meta
    assert {:ok, document} = FileDocuments.get(ctx.root, destination)
    assert document.path == destination
    assert document.version == 2
    assert_receive {:workspace_changed, %{path: ^destination, action: :created}}
    refute_receive {:workspace_changed, _}, 0
  end

  defp metadata_path(ctx, path) do
    encoded = path |> String.trim_leading("/") |> String.replace("/", "__")
    Path.join([ctx.root, ".synapsis/meta", encoded <> ".json"])
  end

  defp own_path(suffix), do: "/agents/agent-a/sessions/#{@session}/#{suffix}"
  defp physical(ctx, path), do: Path.join(ctx.root, String.trim_leading(path, "/"))

  defp fixture(ctx, path, content) do
    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{
               path: path,
               content_body: content,
               agent_id: "agent-a",
               session_id: @session,
               created_by: "agent-a",
               updated_by: "agent-a"
             })
  end
end
