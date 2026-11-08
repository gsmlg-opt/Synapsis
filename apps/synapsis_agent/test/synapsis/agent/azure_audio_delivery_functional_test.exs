defmodule Synapsis.Agent.AzureAudioDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio <<0, 1, 2, 254, 255>>

  for {format, mime} <- [
        {"ogg", "audio/ogg"},
        {"webm", "audio/webm"},
        {"amr", "audio/amr"},
        {"audio", "application/octet-stream"},
        {"mp3", "audio/mpeg"},
        {"opus", "audio/ogg"},
        {"wav", "audio/wav"},
        {"pcm", "application/octet-stream"},
        {"flac", "audio/flac"}
      ] do
    @format format
    @mime mime

    test "#{format} publishes one exact original-root fact and portable delivery reference",
         %{tmp_dir: root} do
      session_id = Ecto.UUID.generate()
      media_root = Path.join(root, "original-azure-audio")
      max_bytes = 4_096

      operation = %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "ordinary-azure-#{@format}",
        tool_name: "synapsis::tts"
      }

      sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

      descriptor = %{
        "uri" => "synapsis-media://audio/#{sha}.#{@format}",
        "sha256" => sha,
        "byte_size" => byte_size(@audio),
        "mime_type" => @mime,
        "format" => @format
      }

      assert {:ok, ^descriptor} = Media.put_audio(@audio, @format, root: media_root)

      assert {:ok, reference} =
               MediaDelivery.publish(descriptor, session_id, operation,
                 root: media_root,
                 max_bytes: max_bytes
               )

      assert %{"version" => 1, "session_id" => ^session_id, "id" => delivery_id} = reference
      assert map_size(reference) == 3
      assert Jason.decode!(Jason.encode!(reference)) == reference
      assert {:ok, ^delivery_id} = Ecto.UUID.cast(delivery_id)
      assert {:ok, "/api/media/audio/" <> path} = MediaDelivery.url(reference)
      assert path == session_id <> "/" <> delivery_id

      fact = %{
        version: 1,
        descriptor: descriptor,
        root: Path.expand(media_root),
        max_bytes: max_bytes,
        invocation: operation
      }

      assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, delivery_id)
      assert [file] = Path.wildcard(Path.join(media_root, "**/*.#{@format}"))
      original = File.stat!(file, time: :posix)

      for _ <- 1..2 do
        reader = Task.async(fn -> MediaDelivery.read(session_id, delivery_id) end)
        assert {:ok, %{audio: @audio, descriptor: ^descriptor}} = Task.await(reader, 5_000)
        assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, delivery_id)
        assert File.read!(file) == @audio
        current = File.stat!(file, time: :posix)

        assert {current.inode, current.mtime, current.size} ==
                 {original.inode, original.mtime, original.size}
      end

      assert {:ok, [^fact]} = Store.list_facts(session_id, :audio_delivery)
    end
  end
end
