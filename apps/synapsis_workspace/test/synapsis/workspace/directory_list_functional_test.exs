defmodule Synapsis.Workspace.DirectoryListFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.{Access, Local}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace
  alias Synapsis.Workspace.{FileDocuments, ToolFiles}
  alias Synapsis.WorkspaceDocuments

  @moduletag :tmp_dir

  # Batch207 ordinary expectations were authored before production changes.
  # Source literals are derived from pinned OpenClaw ls; ownership comes from
  # the frozen batch contract and the existing explicit Workspace scope API.
  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    session = Ecto.UUID.generate()

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a")

    %{
      root: root,
      session: session,
      identity: %{role: :session, agent_id: "agent-a", session_id: session}
    }
  end

  test "physical and real Concord todo entries merge before raw cursor pagination", ctx do
    todos = project_todos(ctx.session)
    prefix = session_path(ctx.session)
    physical = physical(ctx.root, prefix)
    File.mkdir_p!(Path.join(physical, "folder"))
    File.mkdir_p!(Path.join(physical, "todo.md"))
    File.write!(Path.join(physical, "todo.md/shadow-child"), "physical directory child")
    File.write!(Path.join(physical, ".hidden"), "hidden body")
    File.write!(Path.join(physical, "zeta"), "zeta body")
    File.write!(Path.join(physical, "folder/deep.txt"), "nested body")

    assert {:ok, original} =
             FileDocuments.put(ctx.root, %{
               path: prefix <> "/alpha",
               content_body: "alpha body",
               agent_id: "agent-a",
               session_id: ctx.session
             })

    sidecar = metadata_path(ctx.root, prefix <> "/alpha")
    original_metadata = File.read!(sidecar)
    original_stat = File.stat!(sidecar)

    {actual, calls} =
      trace_file_calls(fn -> ToolFiles.list_directory(ctx.identity, %{"path" => prefix}) end)

    # The projected todo is a file even when a physical directory has its name.
    assert actual == result("\".hidden\"\n\"alpha\"\n\"folder/\"\n\"todo.md\"\n\"zeta\"")
    assert_no_body_or_metadata_io(calls, ctx.root)

    first =
      "\".hidden\"\n\"alpha\"\n\n[More entries. Continue with the same path and after=\"alpha\".]"

    assert ToolFiles.list_directory(ctx.identity, %{"path" => prefix, "limit" => 2}) ==
             result(first, "alpha")

    second =
      "\"folder/\"\n\"todo.md\"\n\n[More entries. Continue with the same path and after=\"todo.md\".]"

    assert ToolFiles.list_directory(ctx.identity, %{
             "path" => prefix,
             "limit" => 2,
             "after" => "alpha"
           }) == result(second, "todo.md")

    assert ToolFiles.list_directory(ctx.identity, %{"path" => prefix, "after" => "todo.md"}) ==
             result("\"zeta\"")

    assert Store.get_value(ctx.session, "todos", []) == todos
    assert File.read!(sidecar) == original_metadata

    assert Map.take(File.stat!(sidecar), [:mtime, :ctime, :size, :inode]) ==
             Map.take(original_stat, [:mtime, :ctime, :size, :inode])

    assert {:ok, ^original} = FileDocuments.get(ctx.root, prefix <> "/alpha")
    assert File.read!(Path.join(physical, "alpha")) == "alpha body"
    assert File.read!(Path.join(physical, "todo.md/shadow-child")) == "physical directory child"
    refute File.exists?(metadata_path(ctx.root, prefix <> "/todo.md"))
    refute_receive {:workspace_changed, _}, 0
  end

  test "omitted and empty source paths use session agent and shared logical cwd", ctx do
    prefix = session_path(ctx.session)
    File.mkdir_p!(physical(ctx.root, prefix))
    File.write!(physical(ctx.root, prefix <> "/session.txt"), "session")
    File.write!(physical(ctx.root, "/agents/agent-a/agent.txt"), "agent")
    File.mkdir_p!(physical(ctx.root, "/shared"))
    File.write!(physical(ctx.root, "/shared/shared.txt"), "shared")

    for args <- [%{}, %{"path" => ""}] do
      assert ToolFiles.list_directory(ctx.identity, args) == result("\"session.txt\"")

      assert ToolFiles.list_directory(%{role: :agent, agent_id: "agent-a"}, args) ==
               result("\"agent.txt\"\n\"sessions/\"")

      assert ToolFiles.list_directory(%{role: :global}, args) == result("\"shared.txt\"")
    end

    refute_receive {:workspace_changed, _}, 0
  end

  test "a real todo-only logical directory lists without materializing physical files", ctx do
    todos = project_todos(ctx.session)

    assert ToolFiles.list_directory(ctx.identity, %{}) == result("\"todo.md\"")
    assert Store.get_value(ctx.session, "todos", []) == todos
    assert File.ls!(ctx.root) == []
    refute_receive {:workspace_changed, _}, 0
  end

  test "empty physical directory remains a source empty result and Unicode stays in UTF16 order",
       ctx do
    prefix = session_path(ctx.session)
    File.mkdir_p!(physical(ctx.root, prefix))
    assert ToolFiles.list_directory(ctx.identity, %{}) == result("(empty directory)")
    File.write!(physical(ctx.root, prefix <> "/\uE000"), "bmp")
    File.write!(physical(ctx.root, prefix <> "/\u{10000}"), "supplementary")
    File.write!(physical(ctx.root, prefix <> "/a\nb"), "quoted")

    assert ToolFiles.list_directory(ctx.identity, %{}) ==
             result("\"a\\nb\"\n\"𐀀\"\n\"\"")

    assert ToolFiles.list_directory(ctx.identity, %{"after" => "𐀀"}) == result("\"\"")
    refute_receive {:workspace_changed, _}, 0
  end

  test "Workspace ordinary enumeration uses 500 default rather than the legacy 200", ctx do
    prefix = session_path(ctx.session)
    File.mkdir_p!(physical(ctx.root, prefix))

    for index <- 0..204 do
      name = "file-" <> String.pad_leading(to_string(index), 3, "0")
      File.write!(physical(ctx.root, prefix <> "/" <> name), "ordinary")
    end

    expected =
      Enum.map_join(0..204, "\n", fn index ->
        "\"file-#{String.pad_leading(to_string(index), 3, "0")}\""
      end)

    assert ToolFiles.list_directory(ctx.identity, %{}) == result(expected)
    refute_receive {:workspace_changed, _}, 0
  end

  test "directory callbacks keep explicit original scope pinned root and normal retirement",
       ctx do
    File.mkdir_p!(physical(ctx.root, "/shared/notes/sub"))
    File.write!(physical(ctx.root, "/shared/notes/alpha"), "alpha body")
    File.write!(physical(ctx.root, "/shared/notes/sub/deep.txt"), "deep body")
    other = Path.join(ctx.root, "other-root")
    File.mkdir_p!(other)
    deadline = System.monotonic_time(:millisecond) + 5_000
    owner = self()
    root = ctx.root

    expected =
      MapSet.new([
        %{name: "alpha", is_directory: false},
        %{name: "sub", is_directory: true}
      ])

    task =
      Task.async(fn ->
        Workspace.with_directory_entries("/shared/notes", [deadline: deadline], fn
          {:ok, entries}, scope ->
            worker = self()
            assert worker != owner
            assert MapSet.new(entries) == expected
            assert scope.root == root and scope.io[:deadline] == deadline
            assert :ok = Local.check_scope(scope.io)

            assert {:ok, %{worker_pid: ^worker, owner_pid: guardian, deadline: ^deadline}} =
                     Access.check(scope.io[:lease], [physical(root, "/shared/notes")])

            System.put_env("SYNAPSIS_WORKSPACE_ROOT", other)

            assert WorkspaceDocuments.with_directory_entries("/shared/notes", scope, fn
                     {:ok, nested}, nested_scope ->
                       assert self() == worker and nested_scope == scope
                       assert MapSet.new(nested) == expected

                       assert FileDocuments.with_directory_entries(
                                root,
                                "/shared/notes",
                                nested_scope.io,
                                fn {:ok, raw}, io ->
                                  assert self() == worker and io == scope.io
                                  assert :ok = Local.check_scope(io)
                                  assert MapSet.new(raw) == expected
                                  :raw_complete
                                end
                              ) == :raw_complete

                       :domain_complete
                   end) == :domain_complete

            send(owner, {:workspace_listing_scope, worker, guardian})
            receive do: (:release_workspace_listing -> :complete)
        end)
      end)

    assert_receive {:workspace_listing_scope, worker, guardian}, 1_000
    worker_monitor = Process.monitor(worker)
    guardian_monitor = Process.monitor(guardian)
    on_exit(fn -> send(worker, :release_workspace_listing) end)
    send(worker, :release_workspace_listing)
    assert Task.await(task) == :complete
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
    assert File.ls!(other) == []
    assert File.read!(physical(root, "/shared/notes/alpha")) == "alpha body"
    refute File.exists?(Path.join(root, ".synapsis"))
    refute_receive {:workspace_changed, _}, 0
  end

  defp project_todos(session) do
    assert :ok = Store.ensure_started()
    assert :ok = Store.put_meta(session, %{id: session, agent: "agent-a"})
    now = DateTime.utc_now()

    todos = [
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "first",
        content: "ordinary todo",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert :ok = Store.put_value(session, "todos", todos)
    on_exit(fn -> Store.delete_session(session) end)
    todos
  end

  defp trace_file_calls(callback) do
    functions = [
      {:read, 1},
      {:read!, 1},
      {:open, 2},
      {:write, 2},
      {:write, 3},
      {:write!, 2},
      {:write!, 3}
    ]

    for {name, arity} <- functions do
      :erlang.trace_pattern({File, name, arity}, true, [:local])
    end

    task = Task.async(fn -> receive do: (:list_now -> callback.()) end)
    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :list_now)

    try do
      actual = Task.await(task)
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      {actual, file_calls([])}
    after
      for {name, arity} <- functions do
        :erlang.trace_pattern({File, name, arity}, false, [:local])
      end
    end
  end

  defp file_calls(calls) do
    receive do
      {:trace, _pid, :call, {File, function, arguments}} ->
        file_calls([{function, arguments} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_no_body_or_metadata_io(calls, root) do
    refute Enum.any?(calls, fn
             {_function, [path | _]} when is_binary(path) ->
               path == root or String.starts_with?(path, root <> "/")

             _ ->
               false
           end),
           "listing opened/read/wrote an ordinary body or metadata sidecar"
  end

  defp session_path(session), do: "/agents/agent-a/sessions/#{session}"
  defp physical(root, logical), do: Path.join(root, String.trim_leading(logical, "/"))

  defp metadata_path(root, path) do
    encoded = path |> String.trim_leading("/") |> String.replace("/", "__")
    Path.join([root, ".synapsis/meta", encoded <> ".json"])
  end

  defp result(text),
    do: {:ok, %{content: [%{type: "text", text: text}], details: %{content: text}}}

  defp result(text, after_name),
    do:
      {:ok,
       %{content: [%{type: "text", text: text}], details: %{content: text, nextAfter: after_name}}}
end
