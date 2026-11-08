defmodule Synapsis.Filesystem.AccessFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.Access
  alias Synapsis.Filesystem.Local

  @moduletag :tmp_dir

  # Frozen before batch204 implementation. Only ordinary successful admission,
  # real file effects, and normal owner/worker retirement are exercised here.
  test "an unresolved earlier reservation retains order before key resolution", %{tmp_dir: root} do
    log = event_log()
    first = actor(:first, log)
    later = actor(:later, log)
    witness = actor(:witness, log)
    a = Path.join(root, "a.txt")
    b = Path.join(root, "b.txt")

    submit(later, [a])
    submit(witness, [b])
    # Resolving the first reservation last simulates asynchronous slow physical
    # identity resolution without sleeping or substituting a production resolver.
    submit(first, [a])
    granted(first)
    granted(witness)
    retire(first)
    granted(later)
    retire(later)
    retire(witness)

    assert grant_order(log, [:first, :later]) == [:first, :later]
  end

  test "known intersecting waiters keep FIFO while disjoint paths run", %{tmp_dir: root} do
    log = event_log()
    a = Path.join(root, "a.txt")
    b = Path.join(root, "b.txt")
    c = Path.join(root, "c.txt")
    holder = actor(:holder, log)
    submit(holder, [a])
    granted(holder)
    first = actor(:first, log)
    submit(first, [b, a, b])
    disjoint = actor(:disjoint, log)
    submit(disjoint, [c])
    granted(disjoint)
    # A granted later disjoint reservation is a positive processing barrier:
    # first's keyset is known, since an unresolved reservation blocks all grants.
    second = actor(:second, log)
    submit(second, [b])
    retire(holder)
    granted(first)
    retire(first)
    granted(second)
    retire(second)
    retire(disjoint)

    assert grant_order(log, [:holder, :first, :second, :disjoint]) ==
             [:holder, :disjoint, :first, :second]
  end

  test "opposite multi-key request order grants complete sets without deadlock", %{tmp_dir: root} do
    log = event_log()
    a = Path.join(root, "a.txt")
    b = Path.join(root, "b.txt")
    first = actor(:first, log)
    second = actor(:second, log)
    submit(second, [a, b])
    submit(first, [b, a, b])
    granted(first)
    retire(first)
    granted(second)
    retire(second)

    assert grant_order(log, [:first, :second]) == [:first, :second]
  end

  test "normal worker exit retains its guardian lease until normal guardian exit", %{
    tmp_dir: root
  } do
    log = event_log()
    a = Path.join(root, "a.txt")
    holder = actor(:holder, log)
    submit(holder, [a])
    granted(holder)
    waiter = actor(:waiter, log)
    submit(waiter, [a])
    finish_worker(holder)
    assert Process.alive?(holder.owner)
    witness = actor(:witness, log)
    submit(witness, [Path.join(root, "other.txt")])
    granted(witness)
    finish_owner(holder)
    granted(waiter)
    retire(waiter)
    retire(witness)

    assert Enum.filter(
             events(log),
             &(&1 in [
                 {:worker_exit, :holder},
                 {:grant, :witness},
                 {:owner_exit, :holder},
                 {:grant, :waiter}
               ])
           ) == [
             {:worker_exit, :holder},
             {:grant, :witness},
             {:owner_exit, :holder},
             {:grant, :waiter}
           ]
  end

  test "directory keys intersect descendants but distinguish sibling components", %{tmp_dir: root} do
    log = event_log()
    directory = Path.join(root, "notes")
    holder = actor(:directory, log)
    submit(holder, [directory])
    granted(holder)
    child = actor(:child, log)
    submit(child, [Path.join(directory, "a.txt")])
    sibling = actor(:sibling, log)
    submit(sibling, [Path.join(root, "notes-other/a.txt")])
    granted(sibling)
    retire(holder)
    granted(child)
    retire(child)
    retire(sibling)

    assert grant_order(log, [:directory, :child, :sibling]) ==
             [:directory, :sibling, :child]
  end

  test "nested real reads and writes keep the worker lease and original deadline", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "note.txt"), "one\ntwo\n")
    deadline = deadline()
    caller = self()
    key = Path.join(root, "note.txt")

    assert {:scope_result, "one\nnext\n"} =
             Local.with_paths(root, ["note.txt"], [deadline: deadline], fn scope_opts ->
               assert Keyword.keyword?(scope_opts)
               assert Keyword.fetch!(scope_opts, :deadline) == deadline
               lease = Keyword.fetch!(scope_opts, :lease)
               worker = self()
               assert worker != caller

               assert {:ok, %{owner_pid: owner, worker_pid: ^worker, deadline: ^deadline}} =
                        Access.check(lease, [key])

               assert Process.alive?(owner)

               assert {:ok, "one\ntwo\n", "note.txt"} =
                        Local.read_binary(root, "note.txt", scope_opts)

               assert {:ok, %{content: "two\n", offset: 1}} =
                        Local.perform(
                          root,
                          :file_read,
                          %{"path" => "note.txt", "offset" => 1},
                          scope_opts
                        )

               assert {:ok, %{status: "updated", path: "note.txt", bytes: 9}} =
                        Local.perform(
                          root,
                          :file_write,
                          %{"path" => "note.txt", "content" => "one\nnext\n"},
                          scope_opts
                        )

               Local.with_paths(root, [key], scope_opts, fn nested_opts ->
                 assert self() == worker
                 assert Keyword.fetch!(nested_opts, :lease) == lease
                 assert Keyword.fetch!(nested_opts, :deadline) == deadline

                 assert {:ok, %{owner_pid: ^owner, worker_pid: ^worker, deadline: ^deadline}} =
                          Access.check(lease, [key])

                 assert {:ok, %{content: [%{type: "text", text: "one\nnext\n"}]}} =
                          Local.read_text(root, "./note.txt", %{}, nested_opts)

                 {:scope_result, File.read!(key)}
               end)
             end)

    assert File.read!(key) == "one\nnext\n"
    assert {:ok, "one\nnext\n", "note.txt"} = Local.read_binary(root, "note.txt")
  end

  test "real source planner edit and write consume the existing scoped lease", %{tmp_dir: root} do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    File.write!(Path.join(root, "edit.txt"), "alpha\nbeta\n")
    deadline = deadline()

    assert :complete =
             Local.with_paths(root, ["edit.txt", "write.txt"], [deadline: deadline], fn scope ->
               worker = self()
               lease = Keyword.fetch!(scope, :lease)
               opts = Keyword.put(scope, :node_executable, node)

               assert {:ok, %{details: %{changed: true}}} =
                        Local.edit_text(
                          root,
                          "edit.txt",
                          [%{"oldText" => "beta", "newText" => "gamma"}],
                          opts
                        )

               assert {:ok, %{details: %{changed: true, created: true}}} =
                        Local.write_text(root, "write.txt", "saved\n", opts)

               assert {:ok, %{worker_pid: ^worker, deadline: ^deadline}} =
                        Access.check(lease, [
                          Path.join(root, "edit.txt"),
                          Path.join(root, "write.txt")
                        ])

               assert {:ok, "alpha\ngamma\n", "edit.txt"} =
                        Local.read_binary(root, "edit.txt", scope)

               assert {:ok, "saved\n", "write.txt"} = Local.read_binary(root, "write.txt", scope)
               :complete
             end)

    assert File.read!(Path.join(root, "edit.txt")) == "alpha\ngamma\n"
    assert File.read!(Path.join(root, "write.txt")) == "saved\n"
  end

  test "overlapping roots and equivalent spellings share standalone physical ordering", %{
    tmp_dir: root
  } do
    nested = Path.join(root, "nested")
    File.mkdir_p!(nested)
    target = Path.join(nested, "note.txt")
    File.write!(target, "before\n")
    File.write!(Path.join(root, "other.txt"), "independent\n")
    log = event_log()
    caller = self()

    {operation, monitor} =
      spawn_monitor(fn ->
        result =
          Local.with_paths(root, ["nested/./note.txt"], [], fn scope ->
            worker = self()

            assert {:ok, "before\n", "nested/note.txt"} =
                     Local.read_binary(root, target, scope)

            record(log, :scope_entered)
            send(caller, {:scope_entered, worker})

            receive do
              :finish_scope ->
                assert {:ok, %{status: "updated"}} =
                         Local.perform(
                           root,
                           :file_write,
                           %{"path" => target, "content" => "inside\n"},
                           scope
                         )

                record(log, :scope_completed)
                :inside
            end
          end)

        send(caller, {:scope_returned, result})
      end)

    assert_receive {:scope_entered, worker}, 1_000

    {writer, writer_monitor} =
      spawn_monitor(fn ->
        record(log, :writer_started)
        send(caller, :writer_started)

        result =
          Local.perform(nested, :file_write, %{"path" => "./note.txt", "content" => "after\n"})

        record(log, :writer_completed)
        send(caller, {:writer_returned, result})
      end)

    on_exit(fn -> send(worker, :finish_scope) end)
    assert_receive :writer_started, 1_000
    assert {:ok, "independent\n", "other.txt"} = Local.read_binary(root, "other.txt")
    send(worker, :finish_scope)
    assert_receive {:scope_returned, :inside}, 1_000

    assert_receive {:writer_returned, {:ok, %{status: "updated", path: "note.txt", bytes: 6}}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^operation, :normal}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 1_000
    assert events(log) == [:scope_entered, :writer_started, :scope_completed, :writer_completed]
    assert File.read!(target) == "after\n"
  end

  test "move multi-edit index and search retain ordinary internal contracts in one scope", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.txt"), "red\n")
    File.write!(Path.join(root, "b.txt"), "blue\n")

    assert :complete =
             Local.with_paths(root, [".", "a.txt", "b.txt", "moved.txt"], [], fn scope ->
               assert {:ok,
                       %{
                         status: "updated",
                         files: [
                           %{path: "a.txt", status: "updated", bytes: 6},
                           %{path: "b.txt", status: "updated", bytes: 5}
                         ]
                       }} =
                        Local.perform(
                          root,
                          :multi_edit,
                          %{
                            "edits" => [
                              %{
                                "path" => "b.txt",
                                "old_string" => "blue",
                                "new_string" => "cyan"
                              },
                              %{"path" => "a.txt", "old_string" => "red", "new_string" => "green"}
                            ]
                          },
                          scope
                        )

               assert {:ok, %{status: "moved", source: "a.txt", destination: "moved.txt"}} =
                        Local.perform(
                          root,
                          :file_move,
                          %{"source" => "a.txt", "destination" => "moved.txt"},
                          scope
                        )

               assert {:ok, [%{path: "b.txt", type: "file"}, %{path: "moved.txt", type: "file"}]} =
                        Local.index(root, ".", 1, scope)

               assert {:ok, %{bytes: 6, matches: [%{path: "moved.txt", line: 1, text: "green"}]}} =
                        Local.search_file(root, "moved.txt", "green", scope)

               assert {:ok, %{matches: [%{path: "b.txt", line: 1, text: "cyan"}]}} =
                        Local.perform(root, :grep, %{"path" => ".", "pattern" => "cyan"}, scope)

               assert {:ok, %{paths: ["b.txt", "moved.txt"]}} =
                        Local.perform(root, :glob, %{"path" => ".", "pattern" => "*.txt"}, scope)

               assert {:ok, %{entries: [%{path: "b.txt"}, %{path: "moved.txt"}]}} =
                        Local.perform(root, :list_dir, %{"path" => "."}, scope)

               :complete
             end)

    assert File.read!(Path.join(root, "moved.txt")) == "green\n"
    assert File.read!(Path.join(root, "b.txt")) == "cyan\n"
  end

  defp actor(label, log) do
    test = self()
    deadline = deadline()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        receive do
          :retire -> record(log, {:owner_exit, label})
        end
      end)

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        assert {:ok, lease} = Access.reserve(owner, deadline)
        send(test, {:reserved, label, lease})

        receive do
          {:acquire, keys} ->
            send(test, {:submitted, label})
            assert :ok = Access.acquire(lease, keys)

            assert {:ok, %{owner_pid: ^owner, worker_pid: worker, deadline: ^deadline}} =
                     Access.check(lease, Enum.uniq(keys))

            assert worker == self()
            record(log, {:grant, label})
            send(test, {:granted, label})

            receive do
              :retire -> record(log, {:worker_exit, label})
            end

          :retire ->
            :ok
        end
      end)

    on_exit(fn ->
      send(owner, :retire)
      send(worker, :retire)
    end)

    assert_receive {:reserved, ^label, lease}, 1_000

    %{
      label: label,
      owner: owner,
      owner_monitor: owner_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      lease: lease
    }
  end

  defp submit(actor, keys) do
    send(actor.worker, {:acquire, keys})
    label = actor.label
    assert_receive {:submitted, ^label}, 1_000
  end

  defp granted(actor) do
    label = actor.label
    assert_receive {:granted, ^label}, 1_000
  end

  defp retire(actor) do
    finish_worker(actor)
    finish_owner(actor)
  end

  defp finish_worker(actor) do
    send(actor.worker, :retire)
    %{worker: worker, worker_monitor: monitor} = actor
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end

  defp finish_owner(actor) do
    send(actor.owner, :retire)
    %{owner: owner, owner_monitor: monitor} = actor
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
  end

  defp event_log do
    pid = spawn(fn -> log_loop([]) end)
    on_exit(fn -> send(pid, :retire) end)
    pid
  end

  defp log_loop(events) do
    receive do
      {:record, caller, ref, event} ->
        send(caller, ref)
        log_loop([event | events])

      {:events, caller, ref} ->
        send(caller, {ref, Enum.reverse(events)})
        log_loop(events)

      :retire ->
        :ok
    end
  end

  defp record(log, event) do
    ref = make_ref()
    send(log, {:record, self(), ref, event})
    assert_receive ^ref, 1_000
  end

  defp events(log) do
    ref = make_ref()
    send(log, {:events, self(), ref})
    assert_receive {^ref, result}, 1_000
    result
  end

  defp grant_order(log, labels) do
    for {:grant, label} <- events(log), label in labels, do: label
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
