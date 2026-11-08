defmodule Synapsis.Filesystem.LocalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.Local

  @moduletag :tmp_dir

  setup do
    assert Code.ensure_loaded?(Local), "bounded real-filesystem domain is not implemented"
    :ok
  end

  test "reads zero-based line pages with truthful continuation", %{tmp_dir: root} do
    put(root, "nested/note.txt", "one\n第二行\nthree\n")

    assert {:ok, page} =
             Local.perform(root, :file_read, %{
               "path" => "nested/note.txt",
               "offset" => 1,
               "limit" => 1
             })

    assert page.path == "nested/note.txt"
    assert page.content == "第二行\n"
    assert page.offset == 1 and page.next_offset == 2 and page.truncated
    refute page.partial_line

    assert {:ok, %{content: "three\n", truncated: false, next_offset: nil}} =
             Local.perform(root, :file_read, %{"path" => "nested/note.txt", "offset" => 2})

    assert {:ok, %{content: "", truncated: false, next_offset: nil}} =
             Local.perform(root, :file_read, %{"path" => "nested/note.txt", "offset" => 30})
  end

  test "bounds a long first line without skipping its unread suffix", %{tmp_dir: root} do
    put(root, "long.txt", String.duplicate("界", 30_000) <> "\nnext")
    assert {:ok, page} = Local.perform(root, :file_read, %{"path" => "long.txt"})
    assert page.partial_line and page.truncated and page.next_offset == nil
    assert String.valid?(page.content)
    assert byte_size(page.content) <= 32_768
    refute page.content =~ "next"
  end

  test "rejects traversal, foreign absolute paths, symlink escapes and hardlinks", %{
    tmp_dir: root
  } do
    outside = root <> "-outside"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    on_exit(fn -> File.rm_rf!(outside) end)
    File.ln_s!(outside, Path.join(root, "escape"))
    File.ln!(Path.join(outside, "secret.txt"), Path.join(root, "hard.txt"))

    for path <- [
          "../#{Path.basename(outside)}/secret.txt",
          Path.join(outside, "secret.txt"),
          "escape/secret.txt",
          "hard.txt"
        ] do
      assert {:error, :unsafe_path} = Local.perform(root, :file_read, %{"path" => path})

      assert {:error, :unsafe_path} =
               Local.perform(root, :file_write, %{"path" => path, "content" => "changed"})
    end

    assert File.read!(Path.join(outside, "secret.txt")) == "secret"

    assert {:error, :unsafe_path} =
             Local.perform(root, :file_write, %{
               "path" => "escape/new.txt",
               "content" => "changed"
             })

    refute File.exists?(Path.join(outside, "new.txt"))
  end

  test "rejects malformed inputs, special files and oversized writes", %{tmp_dir: root} do
    for args <- [
          %{},
          %{"path" => "x", "offset" => -1},
          %{"path" => "x", "limit" => 0},
          %{"path" => "x", "limit" => 201},
          %{"path" => "x", "root" => "/"}
        ] do
      assert {:error, :invalid_input} = Local.perform(root, :file_read, args)
    end

    assert {:error, :invalid_input} = Local.perform(root, :file_read, %{"path" => <<255>>})
    assert {:error, :invalid_input} = Local.perform(root, :file_read, %{"path" => "a\0b"})
    assert {:error, :not_regular} = Local.perform(root, :file_read, %{"path" => "."})

    assert {:error, :file_limit} =
             Local.perform(root, :file_write, %{
               "path" => "large",
               "content" => String.duplicate("x", 10 * 1_024 * 1_024 + 1)
             })

    refute File.exists?(Path.join(root, "large"))
  end

  test "write, edit, delete and move retain distinct mutation behavior", %{tmp_dir: root} do
    assert {:ok, %{status: "created", path: "nested/a.txt", bytes: 11}} =
             Local.perform(root, :file_write, %{
               "path" => "nested/a.txt",
               "content" => "first first"
             })

    assert {:ok, %{status: "unchanged"}} =
             Local.perform(root, :file_write, %{
               "path" => "nested/a.txt",
               "content" => "first first"
             })

    assert {:ok, %{status: "updated"}} =
             Local.perform(root, :file_edit, %{
               "path" => "nested/a.txt",
               "old_string" => "first",
               "new_string" => "next"
             })

    assert File.read!(Path.join(root, "nested/a.txt")) == "next first"

    assert {:error, :conflict} =
             Local.perform(root, :file_edit, %{
               "path" => "nested/a.txt",
               "old_string" => "absent",
               "new_string" => "bad"
             })

    assert File.read!(Path.join(root, "nested/a.txt")) == "next first"

    assert {:ok, %{status: "unchanged"}} =
             Local.perform(root, :file_edit, %{
               "path" => "nested/a.txt",
               "old_string" => "next",
               "new_string" => "next"
             })

    assert {:ok, %{status: "moved", source: "nested/a.txt", destination: "other/b.txt"}} =
             Local.perform(root, :file_move, %{
               "source" => "nested/a.txt",
               "destination" => "other/b.txt"
             })

    refute File.exists?(Path.join(root, "nested/a.txt"))
    assert File.read!(Path.join(root, "other/b.txt")) == "next first"

    assert {:ok, %{status: "deleted", path: "other/b.txt"}} =
             Local.perform(root, :file_delete, %{"path" => "other/b.txt"})

    assert {:error, :not_found} = Local.perform(root, :file_delete, %{"path" => "other/b.txt"})
  end

  test "multi-edit validates every target before writes and reports per-file conflicts", %{
    tmp_dir: root
  } do
    put(root, "a.txt", "one two")
    put(root, "b.txt", "other")

    unsafe = [
      %{"path" => "a.txt", "old_string" => "one", "new_string" => "changed"},
      %{"path" => "../outside", "old_string" => "x", "new_string" => "y"}
    ]

    assert {:error, :unsafe_path} = Local.perform(root, :multi_edit, %{"edits" => unsafe})
    assert File.read!(Path.join(root, "a.txt")) == "one two"

    edits = [
      %{"path" => "a.txt", "old_string" => "one", "new_string" => "first"},
      %{"path" => "a.txt", "old_string" => "two", "new_string" => "second"},
      %{"path" => "b.txt", "old_string" => "missing", "new_string" => "bad"}
    ]

    assert {:ok, %{status: "partial", files: files}} =
             Local.perform(root, :multi_edit, %{"edits" => edits})

    assert Enum.map(files, &{&1.path, &1.status}) == [{"a.txt", "updated"}, {"b.txt", "conflict"}]
    assert File.read!(Path.join(root, "a.txt")) == "first second"
    assert File.read!(Path.join(root, "b.txt")) == "other"

    assert {:ok, %{status: "unchanged", files: []}} =
             Local.perform(root, :multi_edit, %{"edits" => []})
  end

  test "directory and glob pages are deterministic and contain only authorized entries", %{
    tmp_dir: root
  } do
    for path <- ["a.txt", "nested/b.ex", "nested/c.ex", "z.txt"], do: put(root, path, "data")

    assert {:ok, %{entries: first, next_offset: 2, truncated: true}} =
             Local.perform(root, :list_dir, %{"path" => ".", "depth" => 2, "limit" => 2})

    assert Enum.map(first, & &1.path) == ["a.txt", "nested"]

    assert {:ok, %{entries: second, next_offset: nil, truncated: false}} =
             Local.perform(root, :list_dir, %{
               "path" => ".",
               "depth" => 2,
               "offset" => 2,
               "limit" => 3
             })

    assert Enum.map(second, & &1.path) == ["nested/b.ex", "nested/c.ex", "z.txt"]

    assert {:ok, %{paths: ["nested/b.ex"], next_offset: 1, truncated: true}} =
             Local.perform(root, :glob, %{"pattern" => "**/*.ex", "limit" => 1})

    assert {:ok, %{paths: ["nested/c.ex"], next_offset: nil, truncated: false}} =
             Local.perform(root, :glob, %{"pattern" => "**/*.ex", "offset" => 1, "limit" => 1})

    assert {:error, :unsafe_path} = Local.perform(root, :glob, %{"pattern" => "../*"})
  end

  test "multi-edit applies relative and inside-root absolute aliases in request order", %{
    tmp_dir: root
  } do
    put(root, "a.txt", "one")

    edits = [
      %{"path" => "a.txt", "old_string" => "one", "new_string" => "two"},
      %{"path" => "./a.txt", "old_string" => "two", "new_string" => "three"},
      %{"path" => Path.join(root, "a.txt"), "old_string" => "three", "new_string" => "four"}
    ]

    result = Local.perform(root, :multi_edit, %{"edits" => edits})

    assert File.read!(Path.join(root, "a.txt")) == "four"
    assert {:ok, %{status: "updated", files: [%{path: "a.txt", status: "updated"}]}} = result
  end

  test "regex search uses real line numbers, include filters, bounded pages and no shell", %{
    tmp_dir: root
  } do
    put(root, "a.ex", "needle one\nother\nneedle two\n")
    put(root, "b.txt", "needle ignored")
    put(root, "c.ex", "--version\n$(touch injected)\n")

    assert {:ok,
            %{
              matches: [%{path: "a.ex", line: 1, text: "needle one"}],
              next_offset: 1,
              truncated: true
            }} =
             Local.perform(root, :grep, %{
               "pattern" => "needle (one|two)",
               "include" => "*.ex",
               "limit" => 1
             })

    assert {:ok, %{matches: [%{path: "a.ex", line: 3}], next_offset: nil, truncated: false}} =
             Local.perform(root, :grep, %{
               "pattern" => "needle (one|two)",
               "include" => "*.ex",
               "offset" => 1,
               "limit" => 1
             })

    assert {:ok, %{matches: [%{path: "c.ex", line: 1}]}} =
             Local.perform(root, :grep, %{"pattern" => "--version"})

    assert {:ok, %{matches: []}} = Local.perform(root, :grep, %{"pattern" => "does-not-exist"})
    assert {:error, :invalid_pattern} = Local.perform(root, :grep, %{"pattern" => "["})
    refute File.exists?(Path.join(root, "injected"))
  end

  test "glob retains Path.wildcard braces classes and dot matching", %{tmp_dir: root} do
    for path <- [
          "a.txt",
          "b.txt",
          "c.txt",
          "lib/a.ex",
          "lib/b.exs",
          ".hidden.ex",
          "lib/.secret.ex",
          ".private/note.ex"
        ],
        do: put(root, path, "data")

    for pattern <- [
          "**/*.{ex,exs}",
          "[ab].txt",
          "[!a].txt",
          "{a,b}.txt",
          "**/*.ex",
          ".*.ex",
          "**/.*.ex",
          "**/*"
        ] do
      expected =
        root
        |> Path.join(pattern)
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.sort()

      assert {:ok, %{paths: actual}} = Local.perform(root, :glob, %{"pattern" => pattern})
      assert actual == expected, "glob semantics changed for #{pattern}"
    end
  end

  test "expired deadline performs no mutation", %{tmp_dir: root} do
    assert {:error, :timeout} =
             Local.perform(root, :file_write, %{"path" => "never.txt", "content" => "never"},
               deadline: System.monotonic_time(:millisecond) - 1
             )

    refute File.exists?(Path.join(root, "never.txt"))
  end

  test "guardian scheduling delay cannot restart an expired mutation deadline", %{tmp_dir: root} do
    Process.flag(:priority, :high)
    owner = self()
    deadline = System.monotonic_time(:millisecond) + 1_000

    caller =
      spawn(fn ->
        receive do
          :go ->
            send(
              owner,
              {:delayed_mutation_finished,
               Local.perform(root, :file_write, %{"path" => "never.txt", "content" => "never"},
                 deadline: deadline
               )}
            )
        end
      end)

    :erlang.trace(caller, true, [:procs, {:tracer, self()}])

    on_exit(fn ->
      Process.exit(caller, :kill)
    end)

    # A high-priority tracer on one scheduler suspends the newly spawned
    # normal-priority guardian before it can run. A call trace alone races
    # with a worker already starting on another scheduler.
    schedulers = :erlang.system_flag(:schedulers_online, 1)

    guardian =
      try do
        send(caller, :go)
        assert_receive {:trace, ^caller, :spawn, guardian, _}, 1_000
        :erlang.suspend_process(guardian)
        assert {:links, []} = Process.info(guardian, :links)
        guardian
      after
        :erlang.system_flag(:schedulers_online, schedulers)
      end

    on_exit(fn -> Process.exit(guardian, :kill) end)
    refute File.exists?(Path.join(root, "never.txt"))
    Process.sleep(max(0, deadline - System.monotonic_time(:millisecond)) + 20)
    :erlang.resume_process(guardian)

    assert_receive {:delayed_mutation_finished, result}, 1_000
    refute File.exists?(Path.join(root, "never.txt"))
    assert result == {:error, :timeout}
  end

  test "oversized multi-edit results are rejected before any content changes", %{tmp_dir: root} do
    directory = Path.join(List.duplicate(String.duplicate("d", 199), 7))

    paths = for index <- 1..200, do: Path.join(directory, "file-#{index}.txt")
    for path <- paths, do: put(root, path, "x")

    edits = Enum.map(paths, &%{"path" => &1, "old_string" => "x", "new_string" => "y"})
    assert {:error, :output_limit} = Local.perform(root, :multi_edit, %{"edits" => edits})
    assert Enum.all?(paths, &(File.read!(Path.join(root, &1)) == "x"))
  end

  test "deadline interruption retains completed mutation evidence", %{tmp_dir: root} do
    assert_interrupted_mutation(root, :timeout)
  end

  test "worker death retains completed mutation evidence", %{tmp_dir: root} do
    assert_interrupted_mutation(root, :worker_limit)
  end

  test "owner death terminates a suspended filesystem worker", %{tmp_dir: root} do
    put(root, "cancel.txt", "cancellable read")
    Process.flag(:priority, :high)
    owner = self()

    caller =
      :erlang.spawn_opt(
        fn ->
          receive do
            :go ->
              send(
                owner,
                {:read_finished, Local.perform(root, :file_read, %{"path" => "cancel.txt"})}
              )
          end
        end,
        [{:priority, :normal}]
      )

    :erlang.trace_pattern({File, :open, 2}, true, [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.exit(caller, :kill)
    end)

    send(caller, :go)
    assert_receive {:trace, worker, :call, {File, :open, _}}, 1_000
    :erlang.suspend_process(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
    refute_receive {:read_finished, _}, 0
  end

  defp assert_interrupted_mutation(root, interruption) do
    put(root, "a.txt", "x")
    put(root, "b.txt", "x")
    Process.flag(:priority, :high)
    owner = self()
    second = Path.join(root, "b.txt")

    caller =
      spawn(fn ->
        receive do
          :go ->
            edits =
              for path <- ["a.txt", "b.txt"],
                  do: %{"path" => path, "old_string" => "x", "new_string" => "y"}

            result =
              Local.perform(root, :multi_edit, %{"edits" => edits},
                deadline: System.monotonic_time(:millisecond) + 1_000
              )

            send(owner, {:mutation_finished, result})
        end
      end)

    :erlang.trace_pattern({File, :open, 2}, true, [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.exit(caller, :kill)
    end)

    send(caller, :go)
    assert_receive {:trace, worker, :call, {File, :open, [^second, _]}}, 1_000
    :erlang.suspend_process(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert File.read!(Path.join(root, "a.txt")) == "y"
    assert File.read!(second) == "x"
    if interruption == :worker_limit, do: Process.exit(worker, :kill)

    assert_receive {:mutation_finished, {:error, {:unknown_outcome, evidence}}}, 2_000
    assert evidence.reason == Atom.to_string(interruption)
    assert Enum.any?(evidence.files, &(&1.path == "a.txt" and &1.status == "updated"))
    assert Enum.any?(evidence.files, &(&1.path == "b.txt" and &1.status == "unknown_outcome"))
  end

  defp put(root, path, content) do
    target = Path.join(root, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
  end
end
