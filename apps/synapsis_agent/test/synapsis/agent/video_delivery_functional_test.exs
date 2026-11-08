defmodule Synapsis.Agent.VideoDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  # These are opaque protocol bytes, not a codec fixture or native invocation.
  @video <<0, 255, 128, "opaque video protocol bytes", 0, 254, 1>>
  @mime_cases [
    {"video/x-msvideo", "avi"},
    {"video/vnd.avi", "avi"},
    {"video/x-m4v", "m4v"},
    {"video/mp4", "mp4"},
    {"video/x-matroska", "mkv"},
    {"video/matroska", "mkv"},
    {"video/webm", "webm"},
    {"video/x-flv", "flv"},
    {"video/x-ms-wmv", "wmv"},
    {"video/quicktime", "mov"},
    {"VIDEO/QUICKTIME; codecs=opaque; profile=1", "mov"},
    {"video/x-synapsis-opaque; vendor=retained", "mp4"}
  ]

  test "video references retain exact MIME descriptors original roots bounds and provenance", %{
    tmp_dir: root
  } do
    session_id = Ecto.UUID.generate()

    for {{mime, format}, index} <- Enum.with_index(@mime_cases) do
      media_root = Path.join(root, "original-#{index}")
      max_bytes = byte_size(@video)
      native = invocation("ordinary-video-fact")
      assert {:ok, descriptor} = Media.put_video(@video, mime, root: media_root)
      assert descriptor["format"] == format
      assert descriptor["mime_type"] == mime

      assert {:ok, reference} =
               MediaDelivery.publish_video(descriptor, session_id, native,
                 root: media_root,
                 max_bytes: max_bytes
               )

      assert %{"version" => 1, "session_id" => ^session_id, "id" => id} = reference
      assert map_size(reference) == 3
      assert {:ok, ^id} = Ecto.UUID.cast(id)
      assert Jason.decode!(Jason.encode!(reference)) == reference
      assert {:ok, "/api/media/video/" <> path} = MediaDelivery.video_url(reference)
      assert path == session_id <> "/" <> id
      assert {:ok, fact} = Store.get_fact(session_id, :video_delivery, id)

      assert fact == %{
               version: 1,
               descriptor: descriptor,
               root: Path.expand(media_root),
               max_bytes: max_bytes,
               invocation: %{
                 run_id: native.run_id,
                 invocation_id: native.invocation_id,
                 tool_call_id: "ordinary-video-fact",
                 tool_name: "synapsis::video"
               }
             }

      for _ <- 1..2 do
        assert {:ok, %{video: @video, descriptor: ^descriptor}} =
                 MediaDelivery.read_video(session_id, id)

        assert {:ok, ^fact} = Store.get_fact(session_id, :video_delivery, id)
      end
    end
  end

  test "distinct invocation provenance sharing a call ID yields fresh stable references", %{
    tmp_dir: root
  } do
    session_id = Ecto.UUID.generate()
    mime = "VIDEO/MP4; codecs=opaque"
    assert {:ok, descriptor} = Media.put_video(@video, mime, root: root)
    operations = [invocation("reused-provider-call"), invocation("reused-provider-call")]

    references =
      Enum.map(operations, fn native ->
        publisher =
          Task.async(fn ->
            MediaDelivery.publish_video(descriptor, session_id, native,
              root: root,
              max_bytes: byte_size(@video)
            )
          end)

        assert {:ok, reference} = Task.await(publisher, 5_000)
        reference
      end)

    assert length(Enum.uniq(references)) == 2
    assert [file] = Path.wildcard(Path.join(root, "**/*.mp4"))
    before_read = File.stat!(file, time: :posix)

    for {reference, native} <- Enum.zip(references, operations) do
      assert {:ok, fact} = Store.get_fact(session_id, :video_delivery, reference["id"])
      assert fact.invocation.run_id == native.run_id
      assert fact.invocation.invocation_id == native.invocation_id
      assert fact.invocation.tool_call_id == "reused-provider-call"

      for _ <- 1..2 do
        reader = Task.async(fn -> MediaDelivery.read_video(session_id, reference["id"]) end)

        assert {:ok, %{video: @video, descriptor: ^descriptor}} = Task.await(reader, 5_000)
        assert {:ok, ^fact} = Store.get_fact(session_id, :video_delivery, reference["id"])
      end
    end

    after_read = File.stat!(file, time: :posix)
    assert {after_read.inode, after_read.mtime} == {before_read.inode, before_read.mtime}
    assert {:ok, facts} = Store.list_facts(session_id, :video_delivery)
    assert length(facts) == 2

    assert Enum.sort(Enum.map(facts, & &1.invocation.invocation_id)) ==
             Enum.sort(Enum.map(operations, & &1.invocation_id))
  end

  test "repeated video reads use the immutable custom bound above 16 MiB", %{tmp_dir: root} do
    session_id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-large-video")
    video = :binary.copy(<<0, 255>>, 8 * 1024 * 1024 + 1)
    max_bytes = byte_size(video) + 1_024
    mime = "video/x-synapsis-opaque; profile=large"
    assert byte_size(video) == 16 * 1024 * 1024 + 2

    assert {:ok, descriptor} =
             Media.put_video(video, mime, root: media_root, max_bytes: max_bytes)

    assert {:ok, reference} =
             MediaDelivery.publish_video(descriptor, session_id, invocation("large-video"),
               root: media_root,
               max_bytes: max_bytes
             )

    assert {:ok, fact} = Store.get_fact(session_id, :video_delivery, reference["id"])
    assert fact.root == Path.expand(media_root)
    assert fact.max_bytes == max_bytes
    assert fact.descriptor == descriptor

    for _ <- 1..2 do
      reader = Task.async(fn -> MediaDelivery.read_video(session_id, reference["id"]) end)
      assert {:ok, %{video: ^video, descriptor: ^descriptor}} = Task.await(reader, 10_000)
      assert {:ok, ^fact} = Store.get_fact(session_id, :video_delivery, reference["id"])
    end

    assert {:ok, [^fact]} = Store.list_facts(session_id, :video_delivery)
  end

  defp invocation(tool_call_id) do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: tool_call_id,
      tool_name: "synapsis::video",
      arguments: %{"prompt" => "Explicit fixture input is not part of the delivery fact"}
    }
  end
end
