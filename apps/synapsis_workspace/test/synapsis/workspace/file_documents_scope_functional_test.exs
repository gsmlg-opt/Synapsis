defmodule Synapsis.Workspace.FileDocumentsScopeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.{Access, Local}
  alias Synapsis.Workspace.{FileDocuments, Resources}
  alias Synapsis.WorkspaceDocuments

  @moduletag :tmp_dir

  # Batch206 ordinary expectations were authored before production changes.
  # Raw compatibility comes from the pre-batch FileDocuments implementation;
  # physical keys below deliberately use its actual slash-to-__ sidecar codec.
  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{root: root}
  end

  test "raw binary get retains the full body attrs and DateTime round trip", %{root: root} do
    bytes = :binary.copy(<<0, 255, 128, 65, 13, 10>>, 20_000)

    assert {:ok, written} =
             FileDocuments.put(root, %{
               path: "/shared/raw.bin",
               content_body: bytes,
               id: "raw-document-id",
               kind: "attachment",
               visibility: "published",
               lifecycle: "archived",
               content_format: "binary",
               metadata: %{origin: "ordinary"},
               created_by: "writer-a",
               updated_by: "writer-b",
               agent_id: "agent-a",
               session_id: "11111111-1111-4111-8111-111111111111"
             })

    assert written.content_body == bytes and byte_size(bytes) == 120_000
    assert %DateTime{} = written.inserted_at
    assert %DateTime{} = written.updated_at
    assert written.version == 1
    assert {:ok, reread} = FileDocuments.get(root, "/shared/raw.bin")
    assert reread == written
    assert File.read!(Path.join(root, "shared/raw.bin")) == bytes

    metadata = Jason.decode!(File.read!(Path.join(root, ".synapsis/meta/shared__raw.bin.json")))
    assert metadata["inserted_at"] == DateTime.to_iso8601(written.inserted_at)
    assert metadata["updated_at"] == DateTime.to_iso8601(written.updated_at)
    refute Map.has_key?(metadata, "content_body")
    assert :ok = FileDocuments.delete(root, "/shared/raw.bin")
    assert [] == Path.wildcard(Path.join(root, "shared/*"))
    assert [] == Path.wildcard(Path.join(root, ".synapsis/meta/*"))
  end

  test "raw attrs precedence defaults and identical bytes preserve legacy version increments", %{
    root: root
  } do
    attrs = %{
      "path" => "/shared/string.yaml",
      "content_body" => "body",
      "kind" => "attachment",
      "metadata" => %{"from" => "string"},
      :path => "/shared/precedence.txt",
      :content_body => "",
      :metadata => %{}
    }

    assert {:ok, first} = FileDocuments.put(root, attrs)
    assert first.path == "/shared/precedence.txt"
    assert first.content_body == "" and first.metadata == %{}
    assert first.kind == "attachment" and first.content_format == "text"
    assert first.visibility == "private" and first.lifecycle == "draft"
    assert first.created_by == nil and first.updated_by == nil
    assert first.agent_id == nil and first.session_id == nil

    assert {:ok, second} =
             FileDocuments.put(root, %{
               "path" => "shared/precedence.txt",
               "content_body" => "",
               "metadata" => %{"revision" => "metadata-only"}
             })

    assert second.id == first.id and second.version == 2
    assert second.inserted_at == first.inserted_at
    assert second.metadata == %{"revision" => "metadata-only"}
    assert {:ok, third} = FileDocuments.put(root, %{path: first.path, content_body: ""})
    assert third.version == 3 and third.id == first.id
    # The immediate attrs result retains string metadata keys; the subsequent
    # raw read recursively atomizes JSON keys before the next put.
    assert third.metadata == %{revision: "metadata-only"}

    assert {:ok, yaml} =
             FileDocuments.put(root, %{"path" => "shared/config.yml", "content_body" => "a: b"})

    assert yaml.content_format == "yaml"

    assert {:ok, json} =
             FileDocuments.put(root, %{path: "/shared/config.json", content_body: "{}"})

    assert json.content_format == "json"
  end

  test "metadata-only list preserves stored paths IDs defaults deep patterns and hidden selection",
       %{
         root: root
       } do
    deep = "/shared/a/b/c/d/e/f/g/h/i/j/k/deep.md"

    for path <- ["/shared/top.txt", "/shared/nested/leaf.md", deep, "/shared/.hidden.md"] do
      assert {:ok, _} =
               FileDocuments.put(root, %{path: path, content_body: "body", created_by: "author"})
    end

    File.write!(Path.join(root, "shared/plain.json"), "{}")
    assert {:ok, rows} = FileDocuments.list_result(root)

    assert Enum.sort(Enum.map(rows, & &1.path)) ==
             Enum.sort([
               "/shared/top.txt",
               "/shared/nested/leaf.md",
               deep,
               "shared/plain.json"
             ])

    assert Enum.all?(rows, &(not Map.has_key?(&1, :content_body)))
    assert Enum.all?(rows, &(not String.starts_with?(&1.path, ".synapsis/meta")))
    assert Enum.find(rows, &(&1.path == "/shared/top.txt")).created_by == "author"
    plain = Enum.find(rows, &(&1.path == "shared/plain.json"))
    assert Map.keys(plain) |> Enum.sort() == [:content_format, :id, :path]
    assert plain.content_format == "json"
    assert plain.id == "f596d272413ef8e064980dc8600ef773"
    assert [%{path: "/shared/top.txt"}] = FileDocuments.list(root, pattern: "shared/*.txt")

    assert [%{path: "/shared/nested/leaf.md"}] =
             FileDocuments.list(root, pattern: "shared/nested/*.md")

    assert [%{path: "/shared/.hidden.md"}] =
             FileDocuments.list(root, pattern: "shared/.hidden.md")

    assert FileDocuments.list(root) == rows
  end

  test "complete domain keys deduplicate aliases and keep worker deadline and pinned root", %{
    root: root
  } do
    access = trace_access()
    owner = self()
    deadline = System.monotonic_time(:millisecond) + 5_000
    other = Path.join(root, "other-root")
    File.mkdir_p!(other)

    keys =
      Enum.sort(
        Enum.map(
          [
            ".synapsis/meta/shared__a__b.txt.json",
            "shared/a/b.txt",
            "shared/a__b.txt"
          ],
          &Path.join(root, &1)
        )
      )

    task =
      Task.async(fn ->
        WorkspaceDocuments.with_paths(
          ["/shared/a/b.txt", "shared/a/b.txt", "/shared/a__b.txt"],
          %{root: root, io: [deadline: deadline]},
          fn scope ->
            worker = self()
            assert worker != owner
            assert scope.root == root and scope.io[:deadline] == deadline
            assert :ok = Local.check_scope(scope.io)

            assert {:ok, %{worker_pid: ^worker, owner_pid: guardian, deadline: ^deadline}} =
                     Access.check(scope.io[:lease], keys)

            send(owner, {:domain_scope, worker, guardian})
            System.put_env("SYNAPSIS_WORKSPACE_ROOT", other)

            assert {:ok, doc} =
                     Resources.upsert("/shared/a/b.txt", "pinned", %{author: "author"}, scope)

            assert WorkspaceDocuments.get_by_path("/shared/a/b.txt", scope).content_body ==
                     "pinned"

            assert FileDocuments.with_paths(root, ["/shared/a/b.txt"], scope.io, fn io ->
                     assert io == scope.io and self() == worker
                     assert {:ok, raw} = FileDocuments.get(root, "/shared/a/b.txt", io)
                     assert raw.id == doc.id
                     :nested
                   end) == :nested

            receive do: (:release_scope -> :complete)
          end
        )
      end)

    assert_receive {:trace, ^access, :receive, {:"$gen_call", {worker, _}, {:acquire, _, ^keys}}},
                   1_000

    assert_receive {:domain_scope, ^worker, guardian}, 1_000
    monitor = Process.monitor(guardian)
    on_exit(fn -> send(worker, :release_scope) end)
    send(worker, :release_scope)
    assert Task.await(task) == :complete
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 1_000
    assert File.read!(Path.join(root, "shared/a/b.txt")) == "pinned"
    assert File.ls!(other) == []
  end

  test "different content paths sharing an actual sidecar serialize with old sequential ID semantics",
       %{
         root: root
       } do
    access = trace_access()
    owner = self()

    first =
      Task.async(fn ->
        FileDocuments.with_paths(root, ["/shared/a/b.txt"], [], fn io ->
          assert {:ok, doc} =
                   FileDocuments.put(root, %{path: "/shared/a/b.txt", content_body: "first"}, io)

          send(owner, {:alias_held, self(), doc.id})
          receive do: (:release_alias -> :first_done)
        end)
      end)

    assert_receive {:alias_held, holder, id}, 1_000
    on_exit(fn -> send(holder, :release_alias) end)

    keys =
      Enum.sort(
        Enum.map(
          [
            ".synapsis/meta/shared__a__b.txt.json",
            "shared/a__b.txt"
          ],
          &Path.join(root, &1)
        )
      )

    second =
      Task.async(fn ->
        result = FileDocuments.put(root, %{path: "/shared/a__b.txt", content_body: "second"})
        send(owner, {:alias_finished, result})
        result
      end)

    assert_receive {:trace, ^access, :receive, {:"$gen_call", {_, _}, {:acquire, _, ^keys}}},
                   1_000

    assert {:ok, disjoint} =
             FileDocuments.put(root, %{path: "/shared/disjoint.txt", content_body: "free"})

    assert disjoint.version == 1
    refute_receive {:alias_finished, _}, 0
    assert File.read!(Path.join(root, "shared/a/b.txt")) == "first"
    send(holder, :release_alias)
    assert Task.await(first) == :first_done
    assert {:ok, second_doc} = Task.await(second)
    assert second_doc.version == 2 and second_doc.id == id
    assert {:ok, original} = FileDocuments.get(root, "/shared/a/b.txt")
    assert original.content_body == "first" and original.version == 2
    assert original.id == id and original.path == "/shared/a/b.txt"
    assert {:ok, alias_doc} = FileDocuments.get(root, "shared/a__b.txt")
    assert alias_doc.content_body == "second" and alias_doc.id == id

    assert [%{path: "/shared/a__b.txt"}, %{path: "/shared/a__b.txt"}] =
             FileDocuments.list(root, pattern: "shared/a*") ++
               FileDocuments.list(root, pattern: "shared/a/*.txt")
  end

  test "root metadata snapshot stays immutable while a real child update waits", %{root: root} do
    assert {:ok, _} =
             FileDocuments.put(root, %{
               path: "/shared/snapshot.txt",
               content_body: "old",
               metadata: %{"phase" => "before"}
             })

    access = trace_access()
    owner = self()

    snapshot =
      Task.async(fn ->
        Local.with_paths(root, ["."], [], fn io ->
          assert {:ok, rows} = FileDocuments.list_result(root, [], io)
          send(owner, {:snapshot_captured, self(), rows})
          receive do: (:release_snapshot -> rows)
        end)
      end)

    assert_receive {:snapshot_captured, holder,
                    [%{version: 1, metadata: %{phase: "before"}}] = rows},
                   1_000

    on_exit(fn -> send(holder, :release_snapshot) end)

    keys =
      Enum.sort(
        Enum.map(
          [
            ".synapsis/meta/shared__snapshot.txt.json",
            "shared/snapshot.txt"
          ],
          &Path.join(root, &1)
        )
      )

    update =
      Task.async(fn ->
        result =
          FileDocuments.put(root, %{
            path: "/shared/snapshot.txt",
            content_body: "new",
            metadata: %{"phase" => "after"}
          })

        send(owner, {:snapshot_child_done, result})
        result
      end)

    assert_receive {:trace, ^access, :receive, {:"$gen_call", {_, _}, {:acquire, _, ^keys}}},
                   1_000

    refute_receive {:snapshot_child_done, _}, 0
    assert File.read!(Path.join(root, "shared/snapshot.txt")) == "old"
    send(holder, :release_snapshot)
    assert Task.await(snapshot) == rows
    assert {:ok, %{version: 2, content_body: "new"}} = Task.await(update)
    assert [%{version: 1, metadata: %{phase: "before"}}] = rows
    assert {:ok, [%{version: 2, metadata: %{phase: "after"}}]} = FileDocuments.list_result(root)
  end

  defp trace_access do
    access = Process.whereis(Access)
    assert is_pid(access)
    assert 1 = :erlang.trace(access, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(access, false, [:receive]) end)
    access
  end
end
