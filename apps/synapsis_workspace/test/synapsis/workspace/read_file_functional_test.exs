defmodule Synapsis.Workspace.ReadFileFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.Store
  alias Synapsis.Workspace
  alias Synapsis.Workspace.{FileDocuments, ToolFiles}
  alias Synapsis.WorkspaceDocuments

  @moduletag :tmp_dir
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  # Batch208 source success envelopes are frozen independently. Real Concord
  # projection rendering follows existing Projection.build_todo_content/1;
  # physical file bytes follow pinned read.ts, not Workspace metadata content.
  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a")
    {:ok, root: root, node: node}
  end

  test "FileDocuments and WorkspaceDocuments read actual neutral-name UTF16 bytes without metadata IO",
       ctx do
    path = "/shared/encoding.bin"

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{path: path, content_body: "metadata baseline"})

    bytes = <<254, 255, 0, 104, 0, 105, 0, 10>>
    File.write!(physical(ctx.root, path), bytes)
    metadata = snapshot(metadata_path(ctx.root, path))
    opts = options(ctx)
    expected = {:ok, text_result("hi\n")}

    {results, calls} =
      trace_file_calls(fn ->
        [
          FileDocuments.read_file(ctx.root, path, %{}, opts),
          WorkspaceDocuments.read_file(path, %{"optional" => true}, opts, ctx.root)
        ]
      end)

    assert results == [expected, expected]
    assert_retired()
    assert_retired()
    assert_no_metadata_io(calls, ctx.root)
    assert File.read!(physical(ctx.root, path)) == bytes
    assert snapshot(metadata_path(ctx.root, path)) == metadata
    refute_receive {:workspace_changed, _}, 0
  end

  test "Workspace and ToolFiles return source inline image envelopes and preserve body and sidecar",
       ctx do
    path = "/shared/picture.bin"

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{path: path, content_body: "metadata baseline"})

    bytes = Base.decode64!(@png)
    File.write!(physical(ctx.root, path), bytes)
    metadata = snapshot(metadata_path(ctx.root, path))
    opts = options(ctx, prefix: "Resolved picture.\n")
    text = "Resolved picture.\nRead image file [image/png]"
    expected = {:ok, image_result(text)}

    {results, calls} =
      trace_file_calls(fn ->
        [
          Workspace.read_file(path, %{}, opts, ctx.root),
          ToolFiles.read_file(%{role: :global}, %{"path" => path, "optional" => true}, opts)
        ]
      end)

    assert results == [expected, expected]
    assert_retired()
    assert_retired()
    assert_no_metadata_io(calls, ctx.root)
    assert File.read!(physical(ctx.root, path)) == bytes
    assert snapshot(metadata_path(ctx.root, path)) == metadata
    refute_receive {:workspace_changed, _}, 0
  end

  test "real Concord projection wins over a physical image and pages text without codec or metadata effects",
       ctx do
    session = Ecto.UUID.generate()
    assert :ok = Store.ensure_started()
    assert :ok = Store.put_meta(session, %{id: session, agent: "agent-a"})
    now = DateTime.utc_now()

    todos = [
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "one",
        content: "ordinary first",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      },
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "two",
        content: "ordinary second",
        status: :completed,
        sort_order: 1,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert :ok = Store.put_value(session, "todos", todos)
    on_exit(fn -> Store.delete_session(session) end)
    path = "/agents/agent-a/sessions/#{session}/todo.md"

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{path: path, content_body: "physical baseline"})

    bytes = Base.decode64!(@png)
    File.write!(physical(ctx.root, path), bytes)
    metadata = snapshot(metadata_path(ctx.root, path))
    opts = options(ctx, prefix: "Projection:")
    identity = %{role: :session, agent_id: "agent-a", session_id: session}

    {actual, calls} =
      trace_file_calls(fn ->
        ToolFiles.read_file(
          identity,
          %{"path" => path, "offset" => 2, "limit" => 1, "optional" => true},
          opts
        )
      end)

    assert actual ==
             {:ok,
              %{
                content: [%{type: "text", text: "Projection:- [x] ordinary second"}],
                details: %{kind: "text", content: "- [x] ordinary second"}
              }}

    # Only projection text is consumed; ordinary source body/metadata stay untouched.
    assert_no_metadata_io(calls, ctx.root)

    refute Enum.any?(calls, fn
             {function, [file | _]} when function in [:read, :read!, :open] ->
               file == physical(ctx.root, path)

             _ ->
               false
           end)

    assert Store.get_value(session, "todos", []) == todos
    assert File.read!(physical(ctx.root, path)) == bytes
    assert snapshot(metadata_path(ctx.root, path)) == metadata
    refute_receive {:filesystem_planner, _, _}, 0
    refute_receive {:workspace_changed, _}, 0
  end

  defp options(ctx, extra \\ []),
    do: Keyword.merge([node_executable: ctx.node, observer_pid: self()], extra)

  defp text_result(text),
    do: %{content: [%{type: "text", text: text}], details: %{kind: "text", content: text}}

  defp image_result(text),
    do: %{
      content: [%{type: "text", text: text}, %{type: "image", data: @png, mimeType: "image/png"}],
      details: %{kind: "image", content: text, mimeType: "image/png"}
    }

  defp physical(root, path), do: Path.join(root, String.trim_leading(path, "/"))

  defp metadata_path(root, path) do
    encoded = path |> String.trim_leading("/") |> String.replace("/", "__")
    Path.join(root, ".synapsis/meta/#{encoded}.json")
  end

  defp snapshot(path),
    do: {File.read!(path), Map.take(File.stat!(path), [:inode, :mtime, :ctime, :size])}

  defp assert_retired do
    assert_receive {:filesystem_planner, broker, status}, 1_000

    assert %{
             phase: :settled,
             outcome: :completed,
             cleanup_confirmed: true,
             exit_status: 0,
             port_released: true,
             os_pid: os_pid,
             port: port
           } = status

    assert is_integer(os_pid) and os_pid > 0
    assert Port.info(port) == nil
    refute Process.alive?(broker)
    refute File.exists?("/proc/#{os_pid}")
  end

  defp trace_file_calls(callback) do
    functions = [
      {:read, 1},
      {:read!, 1},
      {:open, 2},
      {:write, 2},
      {:write, 3},
      {:write!, 2},
      {:write!, 3},
      {:stat, 1},
      {:stat, 2},
      {:lstat, 1},
      {:lstat, 2}
    ]

    for {name, arity} <- functions do
      :erlang.trace_pattern({File, name, arity}, true, [:local])
    end

    task = Task.async(fn -> receive do: (:read_now -> callback.()) end)
    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :read_now)

    try do
      actual = Task.await(task, 20_000)
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

  defp assert_no_metadata_io(calls, root) do
    metadata = Path.join(root, ".synapsis/meta")

    refute Enum.any?(calls, fn
             {_function, [path | _]} when is_binary(path) ->
               path == metadata or String.starts_with?(path, metadata <> "/")

             _ ->
               false
           end),
           "ordinary read inspected or changed metadata sidecars"
  end
end
