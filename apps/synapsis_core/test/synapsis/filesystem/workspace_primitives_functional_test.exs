defmodule Synapsis.Filesystem.WorkspacePrimitivesFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.{Access, Local}

  @moduletag :tmp_dir

  # Independent ordinary literals frozen before batch205 production changes.
  # Source receipts: pinned OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b,
  # edit-plans.json SHA256 a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0.
  # Wildcards follow Elixir Path.Wildcard's default dot-name filtering.
  # Entry exclusions do not alter independent read_patterns (sidecar snapshots).
  # Qualified helper/runtime scope is documented in packages/tool-host/README-filesystem.md;
  # existing planner_effect_functional_test.exs owns detailed Port retirement checks.

  test "binary operations and checks retain the original worker lease and deadline", %{
    tmp_dir: root
  } do
    deadline = System.monotonic_time(:millisecond) + 5_000
    caller = self()

    keys =
      Enum.map(["shared/raw.bin", ".synapsis/meta/shared__raw.bin.json"], &Path.join(root, &1))

    original = <<0, 255, 128, 65, 13, 10>>
    changed = <<255, 0, 66, 10>>

    assert :complete =
             Local.with_paths(
               root,
               ["shared/raw.bin", ".synapsis/meta/shared__raw.bin.json"],
               [deadline: deadline],
               fn scope ->
                 worker = self()
                 assert worker != caller
                 assert Keyword.fetch!(scope, :deadline) == deadline
                 lease = Keyword.fetch!(scope, :lease)
                 assert :ok = Local.check_scope(scope)

                 assert {:ok, %{worker_pid: ^worker, owner_pid: guardian, deadline: ^deadline}} =
                          Access.check(lease, keys)

                 assert Process.alive?(guardian)

                 assert {:ok, %{path: "shared/raw.bin", status: "created", bytes: 6}} =
                          Local.write_binary(root, "shared/raw.bin", original, scope)

                 assert {:ok, ^original, "shared/raw.bin"} =
                          Local.read_binary(root, "shared/raw.bin", scope)

                 assert {:ok, %{path: "shared/raw.bin", status: "updated", bytes: 4}} =
                          Local.write_binary(root, "shared/raw.bin", changed, scope)

                 assert {:ok, %{path: "shared/raw.bin", status: "unchanged", bytes: 4}} =
                          Local.write_binary(root, "shared/raw.bin", changed, scope)

                 Local.with_paths(root, ["shared/raw.bin"], scope, fn nested ->
                   assert self() == worker
                   assert nested == scope
                   assert :ok = Local.check_scope(nested)

                   assert {:ok, ^changed, "shared/raw.bin"} =
                            Local.read_binary(root, "shared/raw.bin", nested)

                   assert {:ok, %{worker_pid: ^worker, owner_pid: ^guardian, deadline: ^deadline}} =
                            Access.check(lease, [Path.join(root, "shared/raw.bin")])

                   :complete
                 end)
               end
             )

    assert File.read!(Path.join(root, "shared/raw.bin")) == changed
    assert {:ok, ^changed, "shared/raw.bin"} = Local.read_binary(root, "shared/raw.bin")
  end

  test "standalone binary writes preserve complete ordinary bodies beyond text pages", %{
    tmp_dir: root
  } do
    bytes = :binary.copy(<<0, 255, 128, 65, 13, 10>>, 20_000)

    assert {:ok, %{path: "full.bin", status: "created", bytes: 120_000}} =
             Local.write_binary(root, "full.bin", bytes)

    assert {:ok, ^bytes, "full.bin"} = Local.read_binary(root, "full.bin")
    assert File.read!(Path.join(root, "full.bin")) == bytes
  end

  test "logical display labels preserve complete source create overwrite and no-op envelopes", %{
    tmp_dir: root
  } do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    path = "/shared/write.txt"
    File.mkdir_p!(Path.join(root, "shared"))
    File.write!(Path.join(root, "shared/overwrite.txt"), "old\n")
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert :complete =
             Local.with_paths(
               root,
               ["shared/write.txt", "shared/overwrite.txt"],
               [deadline: deadline],
               fn scope ->
                 opts = scope ++ [node_executable: node, display_path: path]

                 assert {:ok,
                         %{
                           content: [
                             %{
                               type: "text",
                               text: "Successfully wrote 4 bytes to /shared/write.txt"
                             }
                           ],
                           details: %{
                             changed: true,
                             created: true,
                             diff: "+1 new",
                             firstChangedLine: 1,
                             patch:
                               "--- /shared/write.txt\n+++ /shared/write.txt\n@@ -0,0 +1,1 @@\n+new\n"
                           }
                         }} == Local.write_text(root, "shared/write.txt", "new\n", opts)

                 assert {:ok,
                         %{
                           content: [
                             %{
                               type: "text",
                               text: "Successfully wrote 4 bytes to /shared/overwrite.txt"
                             }
                           ],
                           details: %{
                             changed: true,
                             created: false,
                             diff: "-1 old\n+1 new",
                             firstChangedLine: 1,
                             patch:
                               "--- /shared/overwrite.txt\n+++ /shared/overwrite.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n"
                           }
                         }} ==
                          Local.write_text(
                            root,
                            "shared/overwrite.txt",
                            "new\n",
                            Keyword.put(opts, :display_path, "/shared/overwrite.txt")
                          )

                 assert {:ok,
                         %{
                           content: [
                             %{
                               type: "text",
                               text:
                                 "No changes made to /shared/write.txt. The file already has identical content."
                             }
                           ],
                           details: %{changed: false}
                         }} == Local.write_text(root, "shared/write.txt", "new\n", opts)

                 assert :ok = Local.check_scope(scope)
                 assert Keyword.fetch!(scope, :deadline) == deadline

                 assert {:ok, "new\n", "shared/write.txt"} =
                          Local.read_binary(root, "shared/write.txt", scope)

                 assert {:ok, "new\n", "shared/overwrite.txt"} =
                          Local.read_binary(root, "shared/overwrite.txt", scope)

                 :complete
               end
             )

    assert File.read!(Path.join(root, "shared/write.txt")) == "new\n"
    assert File.read!(Path.join(root, "shared/overwrite.txt")) == "new\n"
  end

  test "logical edit labels retain original-snapshot receipt and normalized no-op bytes", %{
    tmp_dir: root
  } do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    File.mkdir_p!(Path.join(root, "shared"))
    File.write!(Path.join(root, "shared/edit.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(root, "shared/noop.txt"), "alpha\r\nkeep\r\n")

    assert :complete =
             Local.with_paths(root, ["shared/edit.txt", "shared/noop.txt"], [], fn scope ->
               opts = scope ++ [node_executable: node, display_path: "/shared/edit.txt"]

               assert {:ok,
                       %{
                         content: [
                           %{
                             type: "text",
                             text: "Successfully replaced 2 block(s) in /shared/edit.txt."
                           }
                         ],
                         details: %{
                           changed: true,
                           diff: "-1 alpha\n 1 beta\n+2 BETA\n 3 gamma",
                           firstChangedLine: 1,
                           patch:
                             "--- /shared/edit.txt\n+++ /shared/edit.txt\n@@ -1,3 +1,3 @@\n-alpha\n beta\n+BETA\n gamma\n"
                         }
                       }} ==
                        Local.edit_text(
                          root,
                          "shared/edit.txt",
                          [
                            %{"oldText" => "alpha", "newText" => "beta"},
                            %{"oldText" => "beta", "newText" => "BETA"}
                          ],
                          opts
                        )

               assert {:ok,
                       %{
                         content: [
                           %{
                             type: "text",
                             text:
                               "No changes made to /shared/noop.txt. The replacement produced identical content."
                           }
                         ],
                         details: %{changed: false}
                       }} ==
                        Local.edit_text(
                          root,
                          "shared/noop.txt",
                          [
                            %{"oldText" => "alpha\r\n", "newText" => "alpha\n"}
                          ],
                          Keyword.put(opts, :display_path, "/shared/noop.txt")
                        )

               assert :ok = Local.check_scope(scope)

               assert {:ok, "beta\nBETA\ngamma\n", "shared/edit.txt"} =
                        Local.read_binary(root, "shared/edit.txt", scope)

               assert {:ok, "alpha\r\nkeep\r\n", "shared/noop.txt"} =
                        Local.read_binary(root, "shared/noop.txt", scope)

               :complete
             end)

    assert File.read!(Path.join(root, "shared/edit.txt")) == "beta\nBETA\ngamma\n"
    assert File.read!(Path.join(root, "shared/noop.txt")) == "alpha\r\nkeep\r\n"
  end

  test "default snapshot sorts visible metadata without loading document bodies", %{tmp_dir: root} do
    snapshot_fixture(root)

    expected = %{
      entries: [
        %{path: "docs", type: "directory"},
        %{path: "docs/a.md", type: "file"},
        %{path: "docs/b.txt", type: "file"},
        %{path: "docs/nested", type: "directory"},
        %{path: "docs/nested/c1.md", type: "file"},
        %{path: "docs/nested/c2.md", type: "file"},
        %{path: "docs/nested/c3.md", type: "file"},
        %{path: "empty", type: "directory"},
        %{path: "root.txt", type: "file"}
      ],
      files: %{}
    }

    assert {:ok, ^expected} = Local.directory_snapshot(root, ".", %{})
  end

  test "snapshot selectors preserve nested braces ranges hidden literals and component exclusions",
       %{
         tmp_dir: root
       } do
    snapshot_fixture(root)

    cases = [
      {"docs/*.{md,txt}", ["docs/a.md", "docs/b.txt"]},
      {"docs/nested/c[1-2].md", ["docs/nested/c1.md", "docs/nested/c2.md"]},
      {"docs/**/*.md",
       ["docs/a.md", "docs/nested/c1.md", "docs/nested/c2.md", "docs/nested/c3.md"]},
      {".synapsis/meta/*.json", [".synapsis/meta/docs__a.md.json"]},
      {"docs/.visible.md", ["docs/.visible.md"]}
    ]

    for {pattern, paths} <- cases do
      expected = %{entries: Enum.map(paths, &%{path: &1, type: "file"}), files: %{}}
      assert {:ok, ^expected} = Local.directory_snapshot(root, ".", %{pattern: pattern})
    end

    assert {:ok,
            %{
              entries: [
                %{path: "docs/a.md", type: "file"},
                %{path: "docs/b.txt", type: "file"}
              ],
              files: %{".synapsis/meta/docs__a.md.json" => "{\"version\":7}\n"}
            }} ==
             Local.directory_snapshot(root, ".", %{
               pattern: "docs/*.{md,txt}",
               read_patterns: [".synapsis/meta/*.json"]
             })

    put_fixture(root, "meta/a.txt", "excluded")
    put_fixture(root, "metadata/b.txt", "retained")

    assert {:ok,
            %{
              entries: [
                %{path: "metadata", type: "directory"}
              ],
              files: %{"meta/a.txt" => "excluded", "metadata/b.txt" => "retained"}
            }} ==
             Local.directory_snapshot(root, ".", %{
               pattern: "meta*",
               exclude: ["meta"],
               read_patterns: ["meta*/*.txt"]
             })
  end

  test "a nested directory snapshot keeps root-relative results and ordinary depth beyond ten", %{
    tmp_dir: root
  } do
    deep = "docs/a/b/c/d/e/f/g/h/i/j/k/end.txt"
    put_fixture(root, deep, <<0, 255, 65>>)
    put_fixture(root, "docs/top.txt", "top\n")
    put_fixture(root, "outside.txt", "outside\n")

    expected = %{
      entries: [
        %{path: "docs/a/b/c/d/e/f/g/h/i/j/k/end.txt", type: "file"},
        %{path: "docs/top.txt", type: "file"}
      ],
      files: %{
        "docs/a/b/c/d/e/f/g/h/i/j/k/end.txt" => <<0, 255, 65>>,
        "docs/top.txt" => "top\n"
      }
    }

    assert {:ok, ^expected} =
             Local.directory_snapshot(root, "docs", %{
               pattern: "**/*.txt",
               read_patterns: ["**/*.txt"]
             })
  end

  test "root snapshot scope orders child updates while a disjoint root completes", %{tmp_dir: tmp} do
    root = Path.join(tmp, "workspace")
    other = Path.join(tmp, "other-workspace")
    put_fixture(root, "docs/note.txt", "before\n")
    File.mkdir_p!(other)
    parent = self()
    access = Process.whereis(Access)
    assert is_pid(access)
    :erlang.trace(access, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(access, false, [:receive]) end)

    {reader, reader_monitor} =
      spawn_monitor(fn ->
        result =
          Local.with_paths(root, ["."], [], fn scope ->
            assert :ok = Local.check_scope(scope)
            send(parent, {:snapshot_scope_entered, self()})

            receive do
              :capture_snapshot ->
                assert {:ok, snapshot} =
                         Local.directory_snapshot(
                           root,
                           ".",
                           %{
                             pattern: "docs/*.txt",
                             read_patterns: ["docs/*.txt"]
                           },
                           scope
                         )

                assert :ok = Local.check_scope(scope)
                snapshot
            end
          end)

        send(parent, {:snapshot_result, result})
      end)

    assert_receive {:snapshot_scope_entered, snapshot_worker}, 1_000
    on_exit(fn -> send(snapshot_worker, :capture_snapshot) end)
    child_key = Path.join(root, "docs/note.txt")

    {writer, writer_monitor} =
      spawn_monitor(fn ->
        result = Local.write_binary(root, "docs/note.txt", "after\n")
        send(parent, {:child_write_result, result})
      end)

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {queued_worker, _}, {:acquire, _, [^child_key]}}},
                   1_000

    assert is_pid(queued_worker)

    assert {:ok, %{path: "independent.bin", status: "created", bytes: 3}} =
             Local.write_binary(other, "independent.bin", <<0, 255, 42>>)

    assert {:ok, <<0, 255, 42>>, "independent.bin"} = Local.read_binary(other, "independent.bin")
    send(snapshot_worker, :capture_snapshot)

    assert_receive {:snapshot_result,
                    %{
                      entries: [%{path: "docs/note.txt", type: "file"}],
                      files: %{"docs/note.txt" => "before\n"}
                    }},
                   1_000

    assert_receive {:child_write_result,
                    {:ok, %{path: "docs/note.txt", status: "updated", bytes: 6}}},
                   1_000

    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 1_000

    assert {:ok,
            %{
              entries: [%{path: "docs/note.txt", type: "file"}],
              files: %{"docs/note.txt" => "after\n"}
            }} ==
             Local.directory_snapshot(root, ".", %{
               pattern: "docs/*.txt",
               read_patterns: ["docs/*.txt"]
             })
  end

  defp snapshot_fixture(root) do
    for {path, bytes} <- [
          {"docs/a.md", "alpha\n"},
          {"docs/b.txt", "beta\n"},
          {"docs/nested/c1.md", "one\n"},
          {"docs/nested/c2.md", "two\n"},
          {"docs/nested/c3.md", "three\n"},
          {"docs/.visible.md", "literal hidden\n"},
          {".synapsis/meta/docs__a.md.json", "{\"version\":7}\n"},
          {"root.txt", "root\n"}
        ],
        do: put_fixture(root, path, bytes)

    File.mkdir_p!(Path.join(root, "empty"))
  end

  defp put_fixture(root, path, bytes) do
    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, bytes)
  end
end
