defmodule Synapsis.Diffs.ArtifactStoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Diffs.ArtifactStore

  setup do
    partition = System.get_env("MIX_TEST_PARTITION", "0")

    root =
      Path.join(System.tmp_dir!(), "synapsis-diffs-store-#{partition}-#{Ecto.UUID.generate()}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      session_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      invocation: Ecto.UUID.generate()
    }
  end

  test "acknowledges independent viewer and file reservations, completion and live lookup",
       context do
    viewer_attrs = attrs(context, :viewer, 1_800_000)
    file_attrs = attrs(context, :file, 2_400_000)
    assert {:ok, viewer} = ArtifactStore.reserve(viewer_attrs, deadline())
    assert {:ok, file} = ArtifactStore.reserve(file_attrs, deadline())

    assert {:ok, _} = Ecto.UUID.cast(viewer.id)
    assert {:ok, _} = Ecto.UUID.cast(file.id)
    assert viewer.public_id =~ ~r/\A[0-9a-f]{20}\z/
    assert file.public_id =~ ~r/\A[0-9a-f]{20}\z/
    assert viewer.id != file.id
    assert viewer.public_id != file.public_id

    for {reserved, original} <- [{viewer, viewer_attrs}, {file, file_attrs}] do
      assert reserved.state == :reserved
      assert is_integer(reserved.revision)
      assert is_integer(reserved.created_at)
      assert reserved.expires_at - reserved.created_at == original.ttl_ms
      assert Map.take(reserved, Map.keys(original)) == original

      descriptor = descriptor(reserved)

      assert {:ok, completed} =
               ArtifactStore.complete(reserved.id, reserved.revision, descriptor, deadline())

      assert completed.state == :complete
      assert completed.revision == reserved.revision + 1
      assert completed.id == reserved.id
      assert completed.public_id == reserved.public_id
      assert completed.created_at == reserved.created_at
      assert completed.expires_at == reserved.expires_at
      assert completed.descriptor == descriptor
      assert Map.take(completed, Map.keys(original)) == original

      assert {:ok, ^completed} =
               ArtifactStore.lookup(
                 completed.public_id,
                 System.system_time(:millisecond),
                 deadline()
               )

      retire_and_ack(completed)
    end
  end

  test "retains a normal explicit retirement until cleanup is acknowledged", context do
    assert {:ok, reserved} = ArtifactStore.reserve(attrs(context, :viewer, 1_800_000), deadline())

    assert {:ok, completed} =
             ArtifactStore.complete(
               reserved.id,
               reserved.revision,
               descriptor(reserved),
               deadline()
             )

    assert {:ok, retired} =
             ArtifactStore.retire(completed.id, completed.revision, deadline())

    assert retired.state == :cleanup_pending
    assert retired.revision == completed.revision + 1
    assert retired.root == completed.root
    assert retired.descriptor == completed.descriptor
    assert retired.created_at == completed.created_at
    assert retired.expires_at == completed.expires_at

    assert {:ok, pending} = ArtifactStore.pending_cleanup(deadline())
    assert Enum.find(pending, &(&1.id == retired.id)) == retired

    assert :ok = ArtifactStore.ack_removed(retired.id, retired.revision, deadline())
    assert {:ok, remaining} = ArtifactStore.pending_cleanup(deadline())
    assert Enum.filter(remaining, &(&1.id == retired.id)) == []
  end

  defp attrs(context, kind, ttl_ms) do
    attrs = %{
      kind: kind,
      root: context.root,
      max_bytes: 32 * 1024 * 1024,
      session_id: context.session_id,
      agent_id: context.agent_id,
      invocation: context.invocation,
      context: %{"sessionId" => context.session_id, "agentId" => context.agent_id},
      ttl_ms: ttl_ms,
      metadata:
        if(kind == :viewer,
          do: %{"title" => "Value update", "inputKind" => "before_after", "fileCount" => 1},
          else: %{"format" => "png"}
        )
    }

    if kind == :viewer,
      do: Map.put(attrs, :token_hash, sha256(:crypto.strong_rand_bytes(24))),
      else: attrs
  end

  defp descriptor(%{kind: :viewer, public_id: id}) do
    html = "<!doctype html><html><body>Value update</body></html>"
    gzip = :zlib.gzip(html)

    %{
      "version" => 1,
      "kind" => "viewer",
      "artifactId" => id,
      "format" => "html",
      "mimeType" => "text/html; charset=utf-8",
      "encoding" => "gzip",
      "path" => Path.join(id, "viewer.html.gz"),
      "bytes" => byte_size(gzip),
      "decodedBytes" => byte_size(html),
      "sha256" => sha256(gzip)
    }
  end

  defp descriptor(%{kind: :file, public_id: id}) do
    %{
      "version" => 1,
      "kind" => "file",
      "artifactId" => id,
      "format" => "png",
      "mimeType" => "image/png",
      "path" => Path.join(id, "preview.png"),
      "bytes" => 512,
      "sha256" => String.duplicate("a", 64)
    }
  end

  defp retire_and_ack(completed) do
    assert {:ok, retired} =
             ArtifactStore.retire(completed.id, completed.revision, deadline())

    assert retired.state == :cleanup_pending
    assert :ok = ArtifactStore.ack_removed(retired.id, retired.revision, deadline())
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
