defmodule Synapsis.Filesystem.DirectoryListFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.{Access, DirectoryList, Local}

  @moduletag :tmp_dir

  # Batch207 expectations were independently frozen from OpenClaw
  # 488631c18fae7cc541ba8fc8beff6cbb0438787b ls.ts, schemas and limits.
  # Only ordinary successful inputs, real directories, and normal retirement.
  test "empty snapshots preserve the exact source envelope" do
    assert DirectoryList.page([], %{}) == result("(empty directory)")
  end

  test "mixed names retain dotfiles actual directories and JSON quoting" do
    entries = [
      entry("á"),
      entry("sub", true),
      entry("Z"),
      entry(".hidden"),
      entry("a\nb"),
      entry("\ta"),
      entry("\"q\""),
      entry("a"),
      entry("🦀", true),
      entry("A", true)
    ]

    expected =
      "\"\\ta\"\n\"\\\"q\\\"\"\n\".hidden\"\n\"A/\"\n\"Z\"\n\"a\"\n\"a\\nb\"\n\"sub/\"\n\"á\"\n\"🦀/\""

    assert DirectoryList.page(entries, %{}) == result(expected)
  end

  test "UTF16 raw ordering and cursor differ from UTF8 binary order" do
    entries = [entry("\uE000"), entry("\u{10000}")]

    assert DirectoryList.page(entries, %{}) == result("\"𐀀\"\n\"\"")

    first = "\"𐀀\"\n\n[More entries. Continue with the same path and after=\"𐀀\".]"
    assert DirectoryList.page(entries, %{"limit" => 1}) == result(first, "𐀀")
    assert DirectoryList.page(entries, %{"after" => "𐀀"}) == result("\"\"")
  end

  test "cursor is the raw directory name and complete pages omit continuation" do
    entries = [entry("gamma"), entry("alpha", true), entry("beta")]
    first = "\"alpha/\"\n\n[More entries. Continue with the same path and after=\"alpha\".]"
    second = "\"beta\"\n\n[More entries. Continue with the same path and after=\"beta\".]"

    assert DirectoryList.page(entries, %{"limit" => 1}) == result(first, "alpha")

    assert DirectoryList.page(entries, %{"limit" => 1, "after" => "alpha"}) ==
             result(second, "beta")

    assert DirectoryList.page(entries, %{"limit" => 1, "after" => "beta"}) ==
             result("\"gamma\"")

    assert DirectoryList.page(entries, %{"after" => "gamma"}) == result("(empty directory)")
  end

  test "ordinary fractional limits floor and positive fractions below one select one" do
    entries = [entry("gamma"), entry("alpha"), entry("beta")]

    assert DirectoryList.page(entries, %{"limit" => 2.9}) ==
             result(
               "\"alpha\"\n\"beta\"\n\n[More entries. Continue with the same path and after=\"beta\".]",
               "beta"
             )

    assert DirectoryList.page(entries, %{"limit" => 0.5}) ==
             result(
               "\"alpha\"\n\n[More entries. Continue with the same path and after=\"alpha\".]",
               "alpha"
             )

    assert DirectoryList.page(entries, %{"limit" => 1_000_000}) ==
             result("\"alpha\"\n\"beta\"\n\"gamma\"")
  end

  test "default is 500 entries and the 501st ordinary name is a final page" do
    entries = for index <- 0..500, do: entry(numbered_name(index))

    expected =
      Enum.map_join(0..499, "\n", fn index -> "\"#{numbered_name(index)}\"" end) <>
        "\n\n[More entries. Continue with the same path and after=\"file-499\".]"

    assert DirectoryList.page(Enum.reverse(entries), %{}) == result(expected, "file-499")
    assert DirectoryList.page(entries, %{"after" => "file-499"}) == result("\"file-500\"")
  end

  test "real direct capture includes hidden names without descending or reading bodies", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "notes/sub"))
    File.write!(Path.join(root, "notes/sub/inside.txt"), "descendant body")
    File.write!(Path.join(root, "notes/.hidden"), "hidden body")
    File.write!(Path.join(root, "notes/a\nb"), "quoted body")
    File.write!(Path.join(root, "notes/á"), "unicode body")

    assert {:ok, entries} = Local.directory_entries(root, "notes")

    assert MapSet.new(entries) ==
             MapSet.new([entry("sub", true), entry(".hidden"), entry("a\nb"), entry("á")])

    assert Local.list_directory(root, "notes", %{}) ==
             result("\".hidden\"\n\"a\\nb\"\n\"sub/\"\n\"á\"")

    File.mkdir_p!(Path.join(root, "empty"))
    assert Local.list_directory(root, "empty", %{}) == result("(empty directory)")
  end

  test "real listing returns more than the old 200 entries and continues after removal", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "many"))

    for index <- 0..204 do
      File.write!(Path.join([root, "many", numbered_name(index)]), "ordinary body")
    end

    expected = Enum.map_join(0..204, "\n", fn index -> "\"#{numbered_name(index)}\"" end)
    assert Local.list_directory(root, "many", %{}) == result(expected)

    File.mkdir_p!(Path.join(root, "pages/alpha"))
    File.write!(Path.join(root, "pages/beta"), "beta body")
    File.write!(Path.join(root, "pages/gamma"), "gamma body")

    assert Local.list_directory(root, "pages", %{"limit" => 1}) ==
             result(
               "\"alpha/\"\n\n[More entries. Continue with the same path and after=\"alpha\".]",
               "alpha"
             )

    File.rmdir!(Path.join(root, "pages/alpha"))

    assert Local.list_directory(root, "pages", %{"after" => "alpha"}) ==
             result("\"beta\"\n\"gamma\"")
  end

  test "capture and render retain the original worker deadline and normal retirement", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/alpha"), "unchanged")
    owner = self()
    deadline = System.monotonic_time(:millisecond) + 5_000

    task =
      Task.async(fn ->
        Local.with_paths(root, ["notes"], [deadline: deadline], fn io ->
          worker = self()
          assert worker != owner
          assert io[:deadline] == deadline
          assert :ok = Local.check_scope(io)

          assert {:ok, %{worker_pid: ^worker, owner_pid: guardian, deadline: ^deadline}} =
                   Access.check(io[:lease], [Path.join(root, "notes")])

          assert {:ok, [%{name: "alpha", is_directory: false}]} =
                   Local.directory_entries(root, "notes", io)

          assert Local.list_directory(root, "notes", %{}, io) == result("\"alpha\"")
          assert :ok = Local.check_scope(io)
          send(owner, {:listing_scope, worker, guardian})
          receive do: (:release_listing -> :listed)
        end)
      end)

    assert_receive {:listing_scope, worker, guardian}, 1_000
    worker_monitor = Process.monitor(worker)
    guardian_monitor = Process.monitor(guardian)
    on_exit(fn -> send(worker, :release_listing) end)
    send(worker, :release_listing)
    assert Task.await(task) == :listed
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert File.read!(Path.join(root, "notes/alpha")) == "unchanged"
    assert Local.list_directory(root, "notes", %{}) == result("\"alpha\"")
  end

  test "same-directory participants retain order while a disjoint directory progresses", %{
    tmp_dir: root
  } do
    for directory <- ["notes", "other"], do: File.mkdir_p!(Path.join(root, directory))
    File.write!(Path.join(root, "notes/alpha"), "body")
    File.write!(Path.join(root, "other/zeta"), "body")
    owner = self()
    order = :ets.new(:directory_listing_order, [:ordered_set, :public])
    access = Process.whereis(Access)
    assert is_pid(access)
    assert 1 = :erlang.trace(access, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(access, false, [:receive]) end)
    key = Path.join(root, "notes")

    holder =
      Task.async(fn ->
        Local.with_paths(root, ["notes"], [], fn io ->
          assert Local.list_directory(root, "notes", %{}, io) == result("\"alpha\"")
          send(owner, {:directory_held, self()})
          receive do: (:release_holder -> :holder_done)
        end)
      end)

    assert_receive {:directory_held, holder_worker}, 1_000

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {^holder_worker, _}, {:acquire, _, [^key]}}},
                   1_000

    on_exit(fn -> send(holder_worker, :release_holder) end)

    first =
      Task.async(fn ->
        Local.with_paths(root, ["notes"], [], fn io ->
          assert Local.list_directory(root, "notes", %{}, io) == result("\"alpha\"")
          :ets.insert(order, {System.unique_integer([:positive, :monotonic]), :first})
          send(owner, {:first_listing, self()})
          receive do: (:release_first -> :first_done)
        end)
      end)

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {first_worker, _}, {:acquire, _, [^key]}}},
                   1_000

    on_exit(fn -> send(first_worker, :release_first) end)

    second =
      Task.async(fn ->
        Local.with_paths(root, ["notes"], [], fn io ->
          assert Local.list_directory(root, "notes", %{}, io) == result("\"alpha\"")
          :ets.insert(order, {System.unique_integer([:positive, :monotonic]), :second})
          send(owner, :second_listing)
          :second_done
        end)
      end)

    assert_receive {:trace, ^access, :receive, {:"$gen_call", _, {:acquire, _, [^key]}}}, 1_000
    assert Local.list_directory(root, "other", %{}) == result("\"zeta\"")
    send(holder_worker, :release_holder)
    assert Task.await(holder) == :holder_done
    assert_receive {:first_listing, ^first_worker}, 1_000
    send(first_worker, :release_first)
    assert Task.await(first) == :first_done
    assert_receive :second_listing, 1_000
    assert Task.await(second) == :second_done
    assert Enum.map(:ets.tab2list(order), &elem(&1, 1)) == [:first, :second]
  end

  defp entry(name, directory \\ false), do: %{name: name, is_directory: directory}
  defp numbered_name(index), do: "file-" <> String.pad_leading(to_string(index), 3, "0")

  defp result(text),
    do: {:ok, %{content: [%{type: "text", text: text}], details: %{content: text}}}

  defp result(text, after_name),
    do:
      {:ok,
       %{content: [%{type: "text", text: text}], details: %{content: text, nextAfter: after_name}}}
end
