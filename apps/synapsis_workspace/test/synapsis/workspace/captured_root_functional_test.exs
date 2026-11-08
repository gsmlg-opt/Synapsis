defmodule Synapsis.Workspace.CapturedRootFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.Local
  alias Synapsis.Session.Store
  alias Synapsis.Workspace
  alias Synapsis.Workspace.{FileDocuments, ToolFiles}

  @moduletag :tmp_dir

  # Frozen before authorship from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b
  # read.ts, write.ts, edit.ts, file-diff.ts and ls.ts. Captured-root plumbing
  # follows the accepted P3209 Local/Workspace architecture. Both roots contain
  # ordinary existing resources; literal expectations never come from UUT output.
  setup %{tmp_dir: root} do
    captured = Path.join(root, "captured")
    ambient = Path.join(root, "ambient")
    for directory <- [captured, ambient], do: File.mkdir_p!(directory)
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", ambient)
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{captured: captured, ambient: ambient, node: node, identity: %{role: :global}}
  end

  test "physical source read pages actual captured bytes under an existing ambient root", ctx do
    put(ctx.captured, "/shared/read.txt", "captured first\ncaptured second\n")
    put(ctx.ambient, "/shared/read.txt", "ambient first\nambient second\n")
    captured_metadata = sidecar(ctx.captured, "/shared/read.txt")
    ambient_metadata = sidecar(ctx.ambient, "/shared/read.txt")

    assert ToolFiles.read_file(
             ctx.identity,
             %{"path" => "/shared/read.txt", "offset" => 2, "limit" => 1, "optional" => true},
             options(ctx),
             ctx.captured
           ) ==
             {:ok,
              %{
                content: [%{type: "text", text: "captured second\n"}],
                details: %{kind: "text", content: "captured second\n"}
              }}

    assert_retired()

    assert File.read!(physical(ctx.captured, "/shared/read.txt")) ==
             "captured first\ncaptured second\n"

    assert File.read!(physical(ctx.ambient, "/shared/read.txt")) ==
             "ambient first\nambient second\n"

    assert sidecar(ctx.captured, "/shared/read.txt") == captured_metadata
    assert sidecar(ctx.ambient, "/shared/read.txt") == ambient_metadata
  end

  test "source write uses captured root and keeps trusted display spelling throughout receipt",
       ctx do
    put(ctx.captured, "/shared/write.txt", "before\n")
    put(ctx.ambient, "/shared/write.txt", "before\n")
    ambient_metadata = sidecar(ctx.ambient, "/shared/write.txt")

    expected = %{
      content: [
        %{type: "text", text: "Successfully wrote 8 bytes to @synapsis/shared/write.txt"}
      ],
      details: %{
        changed: true,
        created: false,
        diff: "-1 before\n+1 written",
        firstChangedLine: 1,
        patch:
          "--- @synapsis/shared/write.txt\n+++ @synapsis/shared/write.txt\n@@ -1,1 +1,1 @@\n-before\n+written\n"
      }
    }

    assert {:ok, ^expected} =
             ToolFiles.write_text(
               ctx.identity,
               %{"path" => "/shared/write.txt", "content" => "written\n"},
               options(ctx, display_path: "@synapsis/shared/write.txt"),
               ctx.captured
             )

    assert_retired()
    assert File.read!(physical(ctx.captured, "/shared/write.txt")) == "written\n"

    assert {:ok, %{version: 2, content_body: "written\n"}} =
             FileDocuments.get(ctx.captured, "/shared/write.txt")

    assert File.read!(physical(ctx.ambient, "/shared/write.txt")) == "before\n"
    assert sidecar(ctx.ambient, "/shared/write.txt") == ambient_metadata

    assert {:ok, %{version: 1, content_body: "before\n"}} =
             FileDocuments.get(ctx.ambient, "/shared/write.txt")
  end

  test "source edit uses captured snapshot and preserves source display in diff and patch", ctx do
    put(ctx.captured, "/shared/edit.txt", "first\nsecond\n")
    put(ctx.ambient, "/shared/edit.txt", "first\nsecond\n")
    ambient_metadata = sidecar(ctx.ambient, "/shared/edit.txt")

    expected = %{
      content: [
        %{type: "text", text: "Successfully replaced 1 block(s) in @synapsis/shared/edit.txt."}
      ],
      details: %{
        changed: true,
        diff: " 1 first\n-2 second\n+2 updated",
        firstChangedLine: 2,
        patch:
          "--- @synapsis/shared/edit.txt\n+++ @synapsis/shared/edit.txt\n@@ -1,2 +1,2 @@\n first\n-second\n+updated\n"
      }
    }

    assert {:ok, ^expected} =
             ToolFiles.edit_text(
               ctx.identity,
               %{
                 "path" => "/shared/edit.txt",
                 "edits" => [%{"oldText" => "second", "newText" => "updated"}]
               },
               options(ctx, display_path: "@synapsis/shared/edit.txt"),
               ctx.captured
             )

    assert_retired()
    assert File.read!(physical(ctx.captured, "/shared/edit.txt")) == "first\nupdated\n"

    assert {:ok, %{version: 2, content_body: "first\nupdated\n"}} =
             FileDocuments.get(ctx.captured, "/shared/edit.txt")

    assert File.read!(physical(ctx.ambient, "/shared/edit.txt")) == "first\nsecond\n"
    assert sidecar(ctx.ambient, "/shared/edit.txt") == ambient_metadata

    assert {:ok, %{version: 1, content_body: "first\nsecond\n"}} =
             FileDocuments.get(ctx.ambient, "/shared/edit.txt")
  end

  test "source listing and directory scope use captured entries with ambient root populated",
       ctx do
    File.mkdir_p!(physical(ctx.captured, "/shared/listing/folder"))
    File.write!(physical(ctx.captured, "/shared/listing/captured-only.txt"), "captured body\n")
    File.mkdir_p!(physical(ctx.ambient, "/shared/listing"))
    File.write!(physical(ctx.ambient, "/shared/listing/ambient-only.txt"), "ambient body\n")

    assert ToolFiles.list_directory(
             ctx.identity,
             %{"path" => "/shared/listing"},
             [],
             ctx.captured
           ) ==
             {:ok,
              %{
                content: [%{type: "text", text: "\"captured-only.txt\"\n\"folder/\""}],
                details: %{content: "\"captured-only.txt\"\n\"folder/\""}
              }}

    caller = self()
    captured = ctx.captured
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert :captured_directory =
             Workspace.with_directory_entries(
               "/shared/listing",
               [deadline: deadline],
               fn {:ok, entries}, scope ->
                 assert self() != caller
                 assert scope.root == captured
                 assert scope.io[:deadline] == deadline
                 assert :ok = Local.check_scope(scope.io)

                 assert MapSet.new(entries) ==
                          MapSet.new([
                            %{name: "captured-only.txt", is_directory: false},
                            %{name: "folder", is_directory: true}
                          ])

                 :captured_directory
               end,
               captured
             )

    assert File.read!(physical(ctx.captured, "/shared/listing/captured-only.txt")) ==
             "captured body\n"

    assert File.read!(physical(ctx.ambient, "/shared/listing/ambient-only.txt")) ==
             "ambient body\n"
  end

  test "real Concord projection remains first for the same logical URI with a captured root",
       ctx do
    session = Ecto.UUID.generate()
    assert :ok = Store.ensure_started()
    assert :ok = Store.put_meta(session, %{id: session, agent: "agent-a"})
    now = DateTime.utc_now()

    todos = [
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "one",
        content: "captured task",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }
    ]

    assert :ok = Store.put_value(session, "todos", todos)
    on_exit(fn -> Store.delete_session(session) end)
    logical = "/agents/agent-a/sessions/#{session}/todo.md"
    put(ctx.captured, logical, "captured physical body\n")
    put(ctx.ambient, logical, "ambient physical body\n")
    captured_metadata = sidecar(ctx.captured, logical)
    ambient_metadata = sidecar(ctx.ambient, logical)
    identity = %{role: :session, agent_id: "agent-a", session_id: session}

    assert ToolFiles.read_file(identity, %{"path" => logical}, options(ctx), ctx.captured) ==
             {:ok,
              %{
                content: [%{type: "text", text: "- [ ] captured task"}],
                details: %{kind: "text", content: "- [ ] captured task"}
              }}

    assert Store.get_value(session, "todos", []) == todos
    assert File.read!(physical(ctx.captured, logical)) == "captured physical body\n"
    assert File.read!(physical(ctx.ambient, logical)) == "ambient physical body\n"
    assert sidecar(ctx.captured, logical) == captured_metadata
    assert sidecar(ctx.ambient, logical) == ambient_metadata
    refute_receive {:filesystem_planner, _, _}, 0
  end

  defp put(root, logical, bytes) do
    assert {:ok, _} = FileDocuments.put(root, %{path: logical, content_body: bytes})
  end

  defp physical(root, logical), do: Path.join(root, String.trim_leading(logical, "/"))

  defp sidecar(root, logical) do
    encoded = logical |> String.trim_leading("/") |> String.replace("/", "__")
    path = Path.join(root, ".synapsis/meta/#{encoded}.json")
    {File.read!(path), Map.take(File.stat!(path), [:inode, :mtime, :ctime, :size])}
  end

  defp options(ctx, extra \\ []),
    do: Keyword.merge([node_executable: ctx.node, observer_pid: self()], extra)

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
end
