defmodule SynapsisServer.VideoDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  # Opaque synthetic protocol bytes do not establish codec or playback support.
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

  setup do
    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: 5_000}}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    {:ok, port: port}
  end

  test "the actual Endpoint serves full video bytes and lossless MIME for every alias and fallback",
       %{tmp_dir: root, port: port} do
    session_id = Ecto.UUID.generate()

    for {{mime, format}, index} <- Enum.with_index(@mime_cases) do
      media_root = Path.join(root, "original-#{index}")
      assert {:ok, descriptor} = Media.put_video(@video, mime, root: media_root)
      assert descriptor["format"] == format
      assert descriptor["mime_type"] == mime

      assert {:ok, reference} =
               MediaDelivery.publish_video(descriptor, session_id, invocation(),
                 root: media_root,
                 max_bytes: byte_size(@video)
               )

      assert {:ok, path} = MediaDelivery.video_url(reference)
      assert path == "/api/media/video/#{session_id}/#{reference["id"]}"
      assert [file] = Path.wildcard(Path.join(media_root, "**/*." <> format))
      before_read = File.stat!(file, time: :posix)

      for _ <- 1..2 do
        assert {:ok, response} = get_video(port, path)
        assert response.status == 200
        assert response.body == @video
        assert response.headers["content-type"] == [mime]
        assert response.headers["content-length"] == [Integer.to_string(byte_size(@video))]
        assert response.headers["content-disposition"] == ["inline; filename=\"video.#{format}\""]
        assert response.headers["accept-ranges"] == ["none"]
      end

      after_read = File.stat!(file, time: :posix)

      assert {after_read.inode, after_read.mtime, after_read.size} ==
               {before_read.inode, before_read.mtime, before_read.size}
    end
  end

  test "full HTTP delivery retains the publication root and a custom bound above 16 MiB", %{
    tmp_dir: root,
    port: port
  } do
    session_id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-large-video")
    video = :binary.copy(<<0, 255>>, 8 * 1024 * 1024 + 1)
    mime = "video/x-synapsis-opaque; profile=large"
    max_bytes = byte_size(video) + 1_024
    assert byte_size(video) == 16 * 1024 * 1024 + 2

    assert {:ok, descriptor} =
             Media.put_video(video, mime, root: media_root, max_bytes: max_bytes)

    assert {:ok, reference} =
             MediaDelivery.publish_video(descriptor, session_id, invocation(),
               root: media_root,
               max_bytes: max_bytes
             )

    assert {:ok, path} = MediaDelivery.video_url(reference)

    for _ <- 1..2 do
      assert {:ok, response} = get_video(port, path)
      assert response.status == 200
      assert response.body == video
      assert response.headers["content-type"] == [mime]
      assert response.headers["content-length"] == [Integer.to_string(byte_size(video))]
      assert response.headers["content-disposition"] == ["inline; filename=\"video.mp4\""]
      assert response.headers["accept-ranges"] == ["none"]
    end
  end

  defp invocation do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-video-http",
      tool_name: "synapsis::video"
    }
  end

  defp get_video(port, path) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :get,
      url: "http://127.0.0.1:#{port}" <> path,
      headers: [{"accept", "*/*"}],
      raw: true,
      retry: false,
      redirect: false,
      receive_timeout: 10_000,
      request_timeout: 10_000
    )
    |> Req.request()
  end
end
