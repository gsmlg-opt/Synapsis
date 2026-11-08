defmodule Synapsis.Workspace.FilesystemScopeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.AgentMessages
  alias Synapsis.Filesystem.Access
  alias Synapsis.Session.Store
  alias Synapsis.Workspace
  alias Synapsis.Workspace.{FileDocuments, Handoffs, Resources, ToolFiles}
  alias Synapsis.WorkspaceDocuments

  @moduletag :tmp_dir
  @session "11111111-1111-4111-8111-111111111111"
  @base "/agents/agent-a/sessions/11111111-1111-4111-8111-111111111111"

  # Literal source receipts: OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b,
  # edit-plans.json SHA256 a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0.
  # Logical labels below are independently fixed, never read from UUT results.
  # Source planner integration uses the actual packaged helper and qualified Node.
  defmodule GateSender do
    @behaviour Phoenix.PubSub.Sender
    @impl true
    def send(pid, {owner, selected}, event, state) do
      Kernel.send(pid, event)

      case event do
        {:workspace_changed, %{path: path}} when selected == :handoff or path == selected ->
          Kernel.send(owner, {:publication_held, self(), path})
          receive do: (:release_publication -> :ok)

        _ ->
          :ok
      end

      state
    end
  end

  defmodule StageSender do
    @behaviour Phoenix.PubSub.Sender
    @impl true
    def send(pid, {:global, owner}, event, state) do
      Kernel.send(pid, {:handoff_stage, :global, event})
      Kernel.send(owner, {:handoff_global_held, self()})
      receive do: (:release_global_publication -> :ok)
      state
    end

    def send(pid, stage, event, state) do
      Kernel.send(pid, {:handoff_stage, stage, event})
      state
    end
  end

  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a")

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{root: root, identity: %{role: :session, agent_id: "agent-a", session_id: @session}}
  end

  test "raw and source writes share versions while source no-ops leave sidecar bytes and events untouched",
       ctx do
    path = @base <> "/write.txt"

    assert {:ok, first} =
             FileDocuments.put(ctx.root, %{
               path: path,
               content_body: "old\n",
               created_by: "raw-author"
             })

    assert first.version == 1

    expected_write = %{
      content: [%{type: "text", text: "Successfully wrote 4 bytes to " <> path}],
      details: %{
        changed: true,
        created: false,
        diff: "-1 old\n+1 new",
        firstChangedLine: 1,
        patch: "--- " <> path <> "\n+++ " <> path <> "\n@@ -1,1 +1,1 @@\n-old\n+new\n"
      }
    }

    assert {:ok, ^expected_write} =
             ToolFiles.write_text(
               ctx.identity,
               %{"path" => path, "content" => "new\n"},
               planner()
             )

    assert_receive {:workspace_changed, %{path: ^path, action: :updated, resource_id: id}}
    assert id == first.id
    assert {:ok, second} = FileDocuments.get(ctx.root, path)
    assert second.version == 2 and second.created_by == "raw-author"
    assert second.updated_by == "agent-a" and second.session_id == @session
    sidecar = metadata_path(ctx.root, path)
    bytes = File.read!(sidecar)

    expected_write_noop = %{
      content: [
        %{
          type: "text",
          text: "No changes made to " <> path <> ". The file already has identical content."
        }
      ],
      details: %{changed: false}
    }

    expected_edit_noop = %{
      content: [
        %{
          type: "text",
          text:
            "No changes made to " <>
              path <> ". The replacement text is identical to the original."
        }
      ],
      details: %{changed: false}
    }

    assert {:ok, ^expected_write_noop} =
             ToolFiles.write_text(
               ctx.identity,
               %{"path" => path, "content" => "new\n"},
               planner()
             )

    assert {:ok, ^expected_edit_noop} =
             ToolFiles.edit_text(
               ctx.identity,
               %{"path" => path, "edits" => [%{"oldText" => "new", "newText" => "new"}]},
               planner()
             )

    expected_normalized_noop = %{
      content: [
        %{
          type: "text",
          text: "No changes made to " <> path <> ". The replacement produced identical content."
        }
      ],
      details: %{changed: false}
    }

    assert {:ok, ^expected_normalized_noop} =
             ToolFiles.edit_text(
               ctx.identity,
               %{"path" => path, "edits" => [%{"oldText" => "new\r\n", "newText" => "new\n"}]},
               planner()
             )

    assert File.read!(sidecar) == bytes
    assert {:ok, ^second} = FileDocuments.get(ctx.root, path)
    refute_receive {:workspace_changed, _}, 0

    assert {:ok, third} = FileDocuments.put(ctx.root, %{path: path, content_body: "new\n"})
    assert third.version == 3 and third.id == first.id
    assert third.inserted_at == first.inserted_at
    assert File.read!(sidecar) != bytes
    refute_receive {:workspace_changed, _}, 0
  end

  test "source create exposes the exact source envelope and persisted Workspace metadata", ctx do
    path = @base <> "/create.txt"

    expected = %{
      content: [%{type: "text", text: "Successfully wrote 4 bytes to " <> path}],
      details: %{
        changed: true,
        created: true,
        diff: "+1 new",
        firstChangedLine: 1,
        patch: "--- " <> path <> "\n+++ " <> path <> "\n@@ -0,0 +1,1 @@\n+new\n"
      }
    }

    assert {:ok, ^expected} =
             ToolFiles.write_text(
               ctx.identity,
               %{"path" => path, "content" => "new\n"},
               planner()
             )

    assert_receive {:workspace_changed, %{path: ^path, action: :created, resource_id: id}}
    assert {:ok, doc} = FileDocuments.get(ctx.root, path)
    assert doc.id == id and doc.version == 1 and doc.content_body == "new\n"
    assert doc.created_by == "agent-a" and doc.updated_by == "agent-a"
    assert doc.agent_id == "agent-a" and doc.session_id == @session
    assert to_string(doc.visibility) == "private" and to_string(doc.lifecycle) == "scratch"
    assert to_string(doc.content_format) == "text"
    assert %DateTime{} = doc.inserted_at
    assert %DateTime{} = doc.updated_at
    assert File.read!(physical(ctx.root, path)) == "new\n"
  end

  test "source edit plans all replacements against the original snapshot with logical patch labels",
       ctx do
    path = @base <> "/edit.txt"

    assert {:ok, before} =
             FileDocuments.put(ctx.root, %{path: path, content_body: "alpha\nbeta\ngamma\n"})

    expected = %{
      content: [%{type: "text", text: "Successfully replaced 2 block(s) in " <> path <> "."}],
      details: %{
        changed: true,
        diff: "-1 alpha\n 1 beta\n+2 BETA\n 3 gamma",
        firstChangedLine: 1,
        patch:
          "--- " <>
            path <> "\n+++ " <> path <> "\n@@ -1,3 +1,3 @@\n-alpha\n beta\n+BETA\n gamma\n"
      }
    }

    args = %{
      "path" => path,
      "edits" => [
        %{"oldText" => "alpha", "newText" => "beta"},
        %{"oldText" => "beta", "newText" => "BETA"}
      ]
    }

    assert {:ok, ^expected} = ToolFiles.edit_text(ctx.identity, args, planner())
    assert_receive {:workspace_changed, %{path: ^path, action: :updated, resource_id: id}}
    assert id == before.id

    assert {:ok, %{version: 2, content_body: "beta\nBETA\ngamma\n"}} =
             FileDocuments.get(ctx.root, path)

    assert File.read!(physical(ctx.root, path)) == "beta\nBETA\ngamma\n"

    styled_path = @base <> "/styled.txt"

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{
               path: styled_path,
               content_body: "\uFEFFalpha\r\nbeta\r\ngamma\r\n"
             })

    styled_expected = %{
      content: [
        %{type: "text", text: "Successfully replaced 1 block(s) in " <> styled_path <> "."}
      ],
      details: %{
        changed: true,
        diff: "-1 alpha\n-2 beta\n+1 A\n+2 B\n+3 C\n 4 gamma",
        firstChangedLine: 1,
        patch:
          "--- " <>
            styled_path <>
            "\n+++ " <> styled_path <> "\n@@ -1,3 +1,4 @@\n-alpha\n-beta\n+A\n+B\n+C\n gamma\n"
      }
    }

    assert {:ok, ^styled_expected} =
             ToolFiles.edit_text(
               ctx.identity,
               %{
                 "path" => styled_path,
                 "edits" => [%{"oldText" => "alpha\nbeta\n", "newText" => "A\nB\nC\n"}]
               },
               planner()
             )

    assert_receive {:workspace_changed, %{path: ^styled_path, action: :updated}}

    assert {:ok, %{version: 2, content_body: "\uFEFFA\r\nB\r\nC\r\ngamma\r\n"}} =
             FileDocuments.get(ctx.root, styled_path)
  end

  test "source reads accept one-based fractional line pages and UTF16 cursors without metadata changes",
       ctx do
    path = @base <> "/read.txt"
    bytes = "\uFEFFhead\r\n😀tail\r\nlast\n"
    assert {:ok, _} = FileDocuments.put(ctx.root, %{path: path, content_body: bytes})
    metadata = File.read!(metadata_path(ctx.root, path))

    expected = %{
      content: [%{type: "text", text: "tail\n\n[1 more line in file. Use offset=3 to continue.]"}],
      details: %{
        kind: "truncated",
        content: "tail",
        continuation: %{kind: "line", offset: 3, limit: 1},
        truncation: %{
          truncated: true,
          truncatedBy: "lines",
          totalLines: 3,
          totalBytes: 4,
          outputLines: 1,
          outputBytes: 4,
          lastLinePartial: false,
          firstLineExceedsLimit: false,
          maxLines: 1,
          maxBytes: 51_200
        }
      }
    }

    assert {:ok, ^expected} =
             ToolFiles.read_text(ctx.identity, %{
               "path" => path,
               "offset" => 2,
               "cursor" => 2,
               "limit" => 1.9
             })

    assert {:ok,
            %{
              content: [%{type: "text", text: "last\n"}],
              details: %{kind: "text", content: "last\n"}
            }} =
             ToolFiles.read_text(ctx.identity, %{"path" => path, "offset" => 3})

    assert File.read!(physical(ctx.root, path)) == bytes
    assert File.read!(metadata_path(ctx.root, path)) == metadata
    refute_receive {:workspace_changed, _}, 0
  end

  test "projected source read pages the real Concord todo snapshot", ctx do
    :ok = Store.ensure_started()
    session = Ecto.UUID.generate()
    :ok = Store.put_meta(session, %{id: session, agent: "agent-a"})
    now = DateTime.utc_now()

    todos = [
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "first",
        content: "first",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      },
      %Synapsis.SessionTodo{
        session_id: session,
        todo_id: "second",
        content: "second",
        status: :completed,
        sort_order: 1,
        inserted_at: now,
        updated_at: now
      }
    ]

    :ok = Store.put_value(session, "todos", todos)
    on_exit(fn -> Store.delete_session(session) end)
    identity = %{ctx.identity | session_id: session}
    path = "/agents/agent-a/sessions/#{session}/todo.md"

    assert {:ok,
            %{
              content: [%{type: "text", text: "- [x] second"}],
              details: %{kind: "text", content: "- [x] second"}
            }} =
             ToolFiles.read_text(identity, %{"path" => path, "offset" => 2}, prefix: "")

    assert Store.get_value(session, "todos", []) == todos
    refute File.exists?(physical(ctx.root, path))
    refute File.exists?(metadata_path(ctx.root, path))
    refute_receive {:workspace_changed, _}, 0
  end

  test "direct Resources rereads current metadata before updating a supplied older document",
       ctx do
    path = "/shared/resources.txt"

    assert {:ok, stale} =
             Resources.upsert(path, "first", %{author: "first", metadata: %{revision: "first"}})

    assert {:ok, second} =
             Resources.upsert(path, "second", %{
               author: "second",
               metadata: %{revision: "current"}
             })

    assert second.version == 2
    assert {:ok, third} = Resources.update_document(stale, "third", %{author: "third"})
    assert third.version == 3 and third.id == stale.id
    assert third.metadata == %{revision: "current"}
    assert third.created_by == "first" and third.updated_by == "third"
    assert {:ok, by_id} = Resources.get_by_id(third.id)
    assert by_id.content_body == "third" and by_id.version == 3
    assert %Synapsis.WorkspaceDocument{version: 3} = WorkspaceDocuments.get(third.id)
    assert {:ok, raw} = FileDocuments.get(ctx.root, path)
    assert raw.metadata == %{revision: "current"}
    assert raw.version == 3 and raw.content_body == "third"
    refute_receive {:workspace_changed, _}, 0
  end

  test "public write ID delete and current legacy copy move keep their existing success contracts",
       ctx do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")
    source = "/shared/public.txt"
    destination = "/shared/copied.txt"

    assert {:ok, first} =
             Workspace.write(source, "first", %{
               author: "public-author",
               metadata: %{label: "keep"}
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :created, resource_id: id}}
    assert id == first.id
    assert {:ok, second} = Workspace.write(source, "second", %{author: "updater"})
    assert second.version == 2 and second.id == id
    assert_receive {:workspace_changed, %{path: ^source, action: :updated, resource_id: ^id}}
    assert {:ok, moved} = Workspace.move(source, destination)
    assert moved.id == id and moved.path == destination and moved.content == "second"
    assert_receive {:workspace_changed, %{path: ^source, action: :deleted, resource_id: ^id}}
    assert_receive {:workspace_changed, %{path: ^destination, action: :created, resource_id: ^id}}
    # Resources.move currently copies the current source into a destination;
    # retaining the old file and its sidecar is an explicit compatibility limit.
    assert File.read!(physical(ctx.root, source)) == "second"
    assert File.read!(physical(ctx.root, destination)) == "second"
    assert File.exists?(metadata_path(ctx.root, source))
    assert File.exists?(metadata_path(ctx.root, destination))
    assert :ok = Workspace.delete(destination)
    assert_receive {:workspace_changed, %{path: ^destination, action: :deleted, resource_id: ^id}}
    assert {:ok, by_id} = Workspace.read(id)
    assert by_id.path == source and by_id.version == 2 and by_id.metadata == %{label: "keep"}
    assert :ok = Workspace.delete(id)
    assert_receive {:workspace_changed, %{path: ^source, action: :deleted, resource_id: ^id}}
    assert [] == Path.wildcard(Path.join(ctx.root, "shared/*"))
    assert [] == Path.wildcard(Path.join(ctx.root, ".synapsis/meta/*"))
  end

  test "legacy internal file actions still persist metadata and publish actual move changes",
       ctx do
    source = @base <> "/legacy.txt"
    destination = @base <> "/moved.txt"

    assert {:ok, %{path: ^source, status: "created", bytes: 7}} =
             ToolFiles.perform(ctx.identity, :file_write, %{
               "path" => source,
               "content" => "one one"
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :created, resource_id: id}}

    assert {:ok, %{path: ^source, status: "updated", bytes: 7}} =
             ToolFiles.perform(ctx.identity, :file_edit, %{
               "path" => source,
               "old_string" => "one",
               "new_string" => "two"
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :updated, resource_id: ^id}}

    assert {:ok, %{status: "moved", source: ^source, destination: ^destination}} =
             ToolFiles.perform(ctx.identity, :file_move, %{
               "source" => source,
               "destination" => destination
             })

    assert_receive {:workspace_changed, %{path: ^source, action: :deleted, resource_id: ^id}}
    assert_receive {:workspace_changed, %{path: ^destination, action: :created, resource_id: ^id}}
    refute File.exists?(physical(ctx.root, source))
    refute File.exists?(metadata_path(ctx.root, source))
    assert File.read!(physical(ctx.root, destination)) == "two one"

    assert {:ok, %{id: ^id, version: 3, content_body: "two one"}} =
             FileDocuments.get(ctx.root, destination)
  end

  test "source publication retains the exact content sidecar pair until the real broadcast completes",
       ctx do
    path = @base <> "/publication.txt"
    :ok = Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "workspace:agent:agent-a")

    :ok =
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a",
        sender: {GateSender, {self(), path}}
      )

    access = trace_access()
    owner = self()

    writer =
      Task.async(fn ->
        ToolFiles.write_text(ctx.identity, %{"path" => path, "content" => "new\n"}, planner())
      end)

    assert_receive {:publication_held, publisher, ^path}, 1_000
    on_exit(fn -> send(publisher, :release_publication) end)
    monitor = Process.monitor(publisher)
    assert_receive {:workspace_changed, %{path: ^path, action: :created, resource_id: id}}
    metadata = Jason.decode!(File.read!(metadata_path(ctx.root, path)))
    assert metadata["id"] == id and metadata["version"] == 1
    assert File.read!(physical(ctx.root, path)) == "new\n"

    keys =
      Enum.sort(
        Enum.map(
          [
            ".synapsis/meta/agents__agent-a__sessions__11111111-1111-4111-8111-111111111111__publication.txt.json",
            "agents/agent-a/sessions/11111111-1111-4111-8111-111111111111/publication.txt"
          ],
          &Path.join(ctx.root, &1)
        )
      )

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {^publisher, _}, {:acquire, _, ^keys}}},
                   1_000

    reader =
      Task.async(fn ->
        result = FileDocuments.get(ctx.root, path)
        send(owner, {:publication_reader_done, result})
        result
      end)

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {reader_worker, _}, {:acquire, _, ^keys}}},
                   1_000

    assert reader_worker != publisher

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{path: "/shared/free.txt", content_body: "disjoint"})

    refute_receive {:publication_reader_done, _}, 0
    send(publisher, :release_publication)
    assert {:ok, %{details: %{changed: true, created: true}}} = Task.await(writer)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, :normal}, 1_000
    assert {:ok, %{id: ^id, version: 1, content_body: "new\n"}} = Task.await(reader)
  end

  test "real handoff mail artifact receipts and ordered publications retain the same-key lease",
       ctx do
    :ok = Store.ensure_started()
    session = Ecto.UUID.generate()
    :ok = Store.put_meta(session, %{id: session, agent: "agent-a"})
    on_exit(fn -> Store.delete_session(session) end)
    recipient = "workspace-recipient-#{Ecto.UUID.generate()}"
    :ok = Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "workspace:agent:agent-a")

    :ok =
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:agent:agent-a",
        sender: {GateSender, {self(), :handoff}}
      )

    for {topic, stage} <- [
          {"agent:#{recipient}", :mailbox},
          {"tool_effects:#{session}", :session},
          {"tool_effects:global", :global}
        ] do
      metadata = if stage == :global, do: {:global, self()}, else: stage
      :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic, sender: {StageSender, metadata})
    end

    access = trace_access()
    owner = self()

    input = %{
      "to" => recipient,
      "summary" => "Finished analysis",
      "instructions" => "Review findings"
    }

    context = %{agent_id: "agent-a", session_id: session, primary: false}
    handoff = Task.async(fn -> Handoffs.handoff(input, context) end)
    assert_receive {:publication_held, publisher, path}, 1_000

    on_exit(fn ->
      send(publisher, :release_publication)
      send(publisher, :release_global_publication)
    end)

    monitor = Process.monitor(publisher)
    assert_receive {:workspace_changed, %{path: ^path, action: :created, resource_id: id}}
    ref = path |> Path.basename(".json")
    assert path == "/agents/agent-a/handoffs/#{ref}.json"
    assert {:ok, message} = AgentMessages.fetch_by_ref(ref)
    assert message.from_agent_id == "agent-a" and message.to_agent_id == recipient
    assert message.type == "handoff"
    body = Jason.decode!(File.read!(physical(ctx.root, path)))

    assert body == %{
             "ref" => ref,
             "from" => "agent-a",
             "to" => recipient,
             "payload" => message.payload,
             "created_at" => DateTime.to_iso8601(message.inserted_at)
           }

    metadata = Jason.decode!(File.read!(metadata_path(ctx.root, path)))
    assert metadata["id"] == id and metadata["version"] == 1
    assert metadata["kind"] == "handoff" and metadata["content_format"] == "json"
    assert metadata["agent_id"] == "agent-a" and metadata["updated_by"] == "agent-a"
    refute_receive {:handoff_stage, _, _}, 0

    keys =
      Enum.sort([
        Path.join(ctx.root, "agents/agent-a/handoffs/#{ref}.json"),
        Path.join(ctx.root, ".synapsis/meta/agents__agent-a__handoffs__#{ref}.json.json")
      ])

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {^publisher, _}, {:acquire, _, ^keys}}},
                   1_000

    waiter =
      Task.async(fn ->
        result = FileDocuments.get(ctx.root, path)
        send(owner, {:handoff_waiter_done, result})
        result
      end)

    assert_receive {:trace, ^access, :receive,
                    {:"$gen_call", {waiter_worker, _}, {:acquire, _, ^keys}}},
                   1_000

    assert waiter_worker != publisher

    assert {:ok, _} =
             FileDocuments.put(ctx.root, %{path: "/shared/handoff-free.txt", content_body: "free"})

    refute_receive {:handoff_waiter_done, _}, 0
    send(publisher, :release_publication)
    assert_receive {:handoff_stage, stage1, {:agent_envelope, envelope}}, 1_000
    assert stage1 == :mailbox

    assert envelope == %{
             from: "agent-a",
             to: recipient,
             ref: ref,
             type: :handoff,
             payload: message.payload,
             timestamp: message.inserted_at
           }

    assert_receive {:handoff_stage, stage2, effect}, 1_000
    assert stage2 == :session
    assert effect == {:tool_effect, :workspace_changed, %{ref: ref, type: "handoff"}}
    assert_receive {:handoff_stage, stage3, ^effect}, 1_000
    assert stage3 == :global
    assert_receive {:handoff_global_held, ^publisher}, 1_000
    refute_receive {:handoff_waiter_done, _}, 0
    send(publisher, :release_global_publication)
    assert {:ok, receipt} = Task.await(handoff)

    assert receipt == %{
             to: recipient,
             status: "persisted",
             message_status: "persisted",
             message_id: message.id,
             ref: ref,
             artifact_path: path,
             artifact_status: "persisted",
             artifact_content_status: "persisted",
             artifact_metadata_status: "persisted",
             mailbox_publication: "published",
             workspace_publication: "published",
             session_publication: "published",
             global_publication: "published"
           }

    assert_receive {:DOWN, ^monitor, :process, ^publisher, :normal}, 1_000
    assert {:ok, %{id: ^id, version: 1} = artifact} = Task.await(waiter)

    assert artifact.content_body ==
             Jason.encode!(%{
               ref: ref,
               from: "agent-a",
               to: recipient,
               payload: message.payload,
               created_at: message.inserted_at
             })

    assert {:ok, persisted_message} = AgentMessages.fetch(receipt.message_id)
    assert persisted_message.ref == ref
  end

  defp planner, do: [node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")]

  defp physical(root, path), do: Path.join(root, String.trim_leading(path, "/"))

  defp metadata_path(root, path) do
    encoded = path |> String.trim_leading("/") |> String.replace("/", "__")
    Path.join(root, ".synapsis/meta/#{encoded}.json")
  end

  defp trace_access do
    access = Process.whereis(Access)
    assert is_pid(access)
    assert 1 = :erlang.trace(access, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(access, false, [:receive]) end)
    access
  end
end
