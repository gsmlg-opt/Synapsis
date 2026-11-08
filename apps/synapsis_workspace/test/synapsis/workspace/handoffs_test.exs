defmodule Synapsis.Workspace.HandoffsTest do
  use ExUnit.Case, async: false

  alias Synapsis.AgentMessages
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.{FileDocuments, Handoffs, Permissions, ToolFiles}

  @moduletag :tmp_dir
  @metadata_registry Synapsis.Workspace.HandoffsTest.MetadataRegistry

  defmodule GateSender do
    @behaviour Phoenix.PubSub.Sender
    @impl true
    def send(pid, owner, message, state) do
      Kernel.send(pid, message)
      Kernel.send(owner, {:handoff_publication_entered, self()})

      receive do
        :release_handoff_publication -> :ok
      after
        2_000 -> :ok
      end

      state
    end
  end

  defmodule FailingKV do
    def put(_, _, _), do: {:error, :private_storage_diagnostic}
  end

  defmodule BlockingStore do
    def get_meta(id) do
      [{owner, _}] = Registry.lookup(Synapsis.Workspace.HandoffsTest.MetadataRegistry, id)
      send(owner, {:handoff_metadata_entered, self()})

      receive do
        :release_handoff_metadata -> {:ok, %{id: id, agent: "agent-a"}}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  setup %{tmp_dir: root} do
    assert Code.ensure_loaded?(Handoffs), "the Workspace handoff workflow is not implemented"
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, agent: "agent-a"})
    to = "recipient-#{Ecto.UUID.generate()}"

    for topic <- ["agent:#{to}", "workspace:agent:agent-a", "tool_effects:#{id}"] do
      :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)
    end

    on_exit(fn ->
      Store.delete_session(id)

      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{
      root: root,
      context: %{agent_id: "agent-a", session_id: id, primary: false},
      input: %{"to" => to, "summary" => "Finished analysis", "instructions" => "Review findings"}
    }
  end

  test "mail, generated own artifact and publications agree without widening session permissions",
       ctx do
    assert {:ok, receipt} = Handoffs.handoff(ctx.input, ctx.context)
    assert receipt.status == "persisted"
    assert receipt.message_status == "persisted"
    assert receipt.artifact_status == "persisted"
    assert receipt.mailbox_publication == "published"
    assert receipt.workspace_publication == "published"
    assert receipt.session_publication == "published"
    assert receipt.global_publication == "published"
    assert receipt.artifact_path == "/agents/agent-a/handoffs/#{receipt.ref}.json"
    assert {:ok, message} = AgentMessages.fetch(receipt.message_id)
    assert {:ok, doc} = FileDocuments.get(ctx.root, receipt.artifact_path)
    body = Jason.decode!(doc.content_body)
    assert body["ref"] == message.ref
    assert body["from"] == "agent-a" and body["to"] == ctx.input["to"]
    assert body["payload"] == message.payload
    assert body["created_at"] == DateTime.to_iso8601(message.inserted_at)
    assert to_string(doc.kind) == "handoff"
    assert to_string(doc.content_format) == "json"
    assert doc.agent_id == "agent-a" and doc.updated_by == "agent-a"
    assert_receive {:workspace_changed, %{path: path, action: :created}}
    assert path == receipt.artifact_path
    assert_receive {:agent_envelope, %{type: :handoff, ref: ref}}
    assert ref == receipt.ref
    assert_receive {:tool_effect, :workspace_changed, %{ref: ^ref}}

    identity = %{role: :session, agent_id: "agent-a", session_id: ctx.context.session_id}
    assert Permissions.check(identity, path, :write) == :denied

    assert {:error, :permission_denied} =
             ToolFiles.perform(identity, :file_write, %{"path" => path, "content" => "forged"})

    assert File.read!(physical(ctx, path)) == doc.content_body
  end

  test "forged output paths and linked ancestry fail before the durable message", ctx do
    assert {:error, %{effect: "none"}} =
             Handoffs.handoff(
               Map.put(ctx.input, "path", "/agents/other/handoffs/a.json"),
               ctx.context
             )

    outside = ctx.root <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)
    File.mkdir_p!(Path.join(ctx.root, "agents/agent-a"))
    File.ln_s!(outside, Path.join(ctx.root, "agents/agent-a/handoffs"))
    assert {:error, %{effect: "none"}} = Handoffs.handoff(ctx.input, ctx.context)
    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    assert File.ls!(outside) == []
    refute_receive {:agent_envelope, _}, 0
    refute_receive {:workspace_changed, _}, 0
  end

  test "uncertain mail writes never create an artifact or publish", ctx do
    assert {:error, %{effect: "uncertain", code: "storage_failed"} = receipt} =
             Handoffs.handoff(ctx.input, ctx.context, kv: FailingKV)

    assert is_binary(receipt.ref) and is_binary(receipt.message_id)
    assert receipt.artifact_status == "not_attempted"
    assert receipt.mailbox_publication == "not_published"
    assert Path.wildcard(Path.join(ctx.root, "agents/**/*")) == []
    refute_receive {:agent_envelope, _}, 0
    refute_receive {:workspace_changed, _}, 0
  end

  test "a failed artifact write retains mail and stops later publication", ctx do
    directory = Path.join(ctx.root, "agents/agent-a/handoffs")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o555)
    on_exit(fn -> File.chmod(directory, 0o755) end)

    assert {:error, %{effect: "completed"} = receipt} = Handoffs.handoff(ctx.input, ctx.context)
    assert receipt.message_status == "persisted"
    assert receipt.artifact_status == "failed"
    assert receipt.mailbox_publication == "not_published"
    assert {:ok, %{type: "handoff"}} = AgentMessages.fetch(receipt.message_id)
    assert File.ls!(directory) == []
    refute_receive {:agent_envelope, _}, 0
    refute_receive {:workspace_changed, _}, 0
    refute_receive {:tool_effect, _, _}, 0
  end

  test "metadata failure exposes persisted content without claiming a complete artifact", ctx do
    directory = Path.join(ctx.root, ".synapsis/meta")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o555)
    on_exit(fn -> File.chmod(directory, 0o755) end)

    assert {:error, %{effect: "uncertain"} = receipt} = Handoffs.handoff(ctx.input, ctx.context)
    assert receipt.message_status == "persisted"
    assert receipt.artifact_status == "unknown"
    assert receipt.artifact_content_status == "persisted"
    assert receipt.artifact_metadata_status == "unconfirmed"
    assert {:ok, message} = AgentMessages.fetch(receipt.message_id)
    assert Jason.decode!(File.read!(physical(ctx, receipt.artifact_path)))["ref"] == message.ref
    assert receipt.mailbox_publication == "not_published"
    refute_receive {:agent_envelope, _}, 0
    refute_receive {:workspace_changed, _}, 0
  end

  test "one expired deadline prevents every write and publication", ctx do
    assert {:error, %{effect: "none", code: "timeout"}} =
             Handoffs.handoff(ctx.input, ctx.context,
               deadline: System.monotonic_time(:millisecond) - 1
             )

    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    assert Path.wildcard(Path.join(ctx.root, "agents/**/*")) == []
    refute_receive {:agent_envelope, _}, 0
  end

  test "missing session metadata rejects before either durable write", ctx do
    :ok = Store.delete_session(ctx.context.session_id)

    assert {:error, %{effect: "none", code: "not_found"}} =
             Handoffs.handoff(ctx.input, ctx.context)

    assert_no_handoff_effects(ctx)
  end

  test "the overall deadline includes a blocked session metadata read and terminates its reader",
       ctx do
    metadata_gate(ctx)
    test_owner = self()
    started = System.monotonic_time(:millisecond)

    owner =
      spawn(fn ->
        result =
          Handoffs.handoff(ctx.input, ctx.context,
            store: BlockingStore,
            deadline: started + 500
          )

        send(test_owner, {:handoff_metadata_result, result})
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:handoff_metadata_entered, reader}, 1_000
    monitor = Process.monitor(reader)

    assert_receive {:handoff_metadata_result,
                    {:error, %{effect: "none", code: "timeout"} = receipt}},
                   1_500

    assert System.monotonic_time(:millisecond) - started < 1_500
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1_000
    assert receipt.message_status == "not_attempted"
    assert receipt.artifact_status == "not_attempted"
    assert_no_handoff_effects(ctx)
  end

  test "caller loss terminates a blocked session metadata reader before any handoff effect",
       ctx do
    metadata_gate(ctx)
    owner = spawn(fn -> Handoffs.handoff(ctx.input, ctx.context, store: BlockingStore) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:handoff_metadata_entered, reader}, 1_000
    monitor = Process.monitor(reader)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1_000
    send(reader, :release_handoff_metadata)
    assert_no_handoff_effects(ctx)
  end

  test "caller cancellation stops the blocked publication owner and later side effects", ctx do
    topic = "agent:#{ctx.input["to"]}"
    :ok = Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic, sender: {GateSender, self()})
    owner = spawn(fn -> Handoffs.handoff(ctx.input, ctx.context) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:handoff_publication_entered, publisher}, 1_000
    assert_receive {:agent_envelope, %{type: :handoff, ref: ref}}, 1_000
    monitor = Process.monitor(publisher)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 1_000
    send(publisher, :release_handoff_publication)
    assert {:ok, %{type: "handoff"} = message} = AgentMessages.fetch_by_ref(ref)
    assert message.status != "expired"
    assert File.exists?(physical(ctx, "/agents/agent-a/handoffs/#{ref}.json"))
    refute_receive {:tool_effect, _, _}, 30
  end

  test "deadline during publication retains both stores and marks the entered publication unknown",
       ctx do
    topic = "agent:#{ctx.input["to"]}"
    :ok = Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic, sender: {GateSender, self()})

    task =
      Task.async(fn ->
        Handoffs.handoff(ctx.input, ctx.context,
          deadline: System.monotonic_time(:millisecond) + 500
        )
      end)

    assert_receive {:handoff_publication_entered, publisher}, 1_000
    monitor = Process.monitor(publisher)
    assert {:error, %{effect: "uncertain"} = receipt} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 1_000
    assert receipt.message_status == "persisted"
    assert receipt.artifact_status == "persisted"
    assert receipt.mailbox_publication == "unknown"
    assert {:ok, _} = AgentMessages.fetch(receipt.message_id)
    assert File.exists?(physical(ctx, receipt.artifact_path))
    refute_receive {:tool_effect, _, _}, 0
  end

  defp metadata_gate(ctx) do
    start_supervised!({Registry, keys: :unique, name: @metadata_registry})
    {:ok, _} = Registry.register(@metadata_registry, ctx.context.session_id, nil)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_effects:global")
  end

  defp assert_no_handoff_effects(ctx) do
    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    assert Path.wildcard(Path.join(ctx.root, "agents/**/*")) == []
    assert Path.wildcard(Path.join(ctx.root, ".synapsis/meta/**/*")) == []
    refute_receive {:agent_envelope, _}, 0
    refute_receive {:workspace_changed, _}, 0
    refute_receive {:tool_effect, _, _}, 0
  end

  defp physical(ctx, path), do: Path.join(ctx.root, String.trim_leading(path, "/"))
end
