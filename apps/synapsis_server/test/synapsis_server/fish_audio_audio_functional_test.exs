defmodule SynapsisServer.FishAudioAudioFunctionalTest do
  use SynapsisServer.ChannelCase
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias Synapsis.{Message, Part, Session}

  @moduletag :tmp_dir
  @timeout 5_000
  # Opaque bytes qualify byte conservation and MIME, not codec playback.
  @cases [{"mp3", "audio/mpeg", "mp3", <<255, 251, "ordinary Fish endpoint MP3", 0>>}]

  setup do
    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: @timeout}}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    {:ok, port: port}
  end

  test "actual Endpoint preserves MP3 bytes MIME filename and original durable fact",
       %{tmp_dir: root, port: port} do
    for {label, _download_mime, format, bytes} <- @cases do
      media_root = Path.join(root, "original-#{label}")
      expected = descriptor(format, bytes)
      assert {:ok, ^expected} = Media.put_audio(bytes, format, root: media_root)
      session_id = Ecto.UUID.generate()

      assert {:ok, reference} =
               MediaDelivery.publish(expected, session_id, invocation(label),
                 root: media_root,
                 max_bytes: 4_096
               )

      assert {:ok, fact} = RuntimeStore.get_fact(session_id, :audio_delivery, reference["id"])
      assert fact.root == media_root
      assert fact.descriptor == expected
      assert {:ok, path} = MediaDelivery.url(reference)
      assert path == "/api/media/audio/#{session_id}/#{reference["id"]}"
      assert [file] = Path.wildcard(Path.join(media_root, "**/*.#{format}"))
      original = File.stat!(file, time: :posix)

      for _ <- 1..2 do
        {status, headers, body} = get_audio(port, path, expected["mime_type"])
        assert status == 200
        assert {"content-type", expected["mime_type"]} in headers
        assert {"content-length", Integer.to_string(byte_size(bytes))} in headers
        assert {"content-disposition", "inline; filename=\"audio.#{format}\""} in headers
        assert body == bytes
        assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == expected["sha256"]
      end

      assert {:ok, %{audio: ^bytes, descriptor: ^expected}} =
               MediaDelivery.read(session_id, reference["id"])

      assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, reference["id"])
      current = File.stat!(file, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end
  end

  test "REST and channel retain Audio Parts and projected TTS results through Concord history",
       %{tmp_dir: root} do
    session = %Session{
      id: Ecto.UUID.generate(),
      provider: "ordinary-fish-audio-audio-history",
      model: "fixture"
    }

    assert :ok = Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    {parts, expected} =
      Enum.map(@cases, fn {label, _download_mime, format, bytes} ->
        media_root = Path.join(root, "history-#{label}")
        descriptor = descriptor(format, bytes)
        assert {:ok, ^descriptor} = Media.put_audio(bytes, format, root: media_root)

        assert {:ok, delivery} =
                 MediaDelivery.publish(descriptor, session.id, invocation(label),
                   root: media_root,
                   max_bytes: 4_096
                 )

        assert {:ok, %{audio: ^bytes, descriptor: ^descriptor}} =
                 MediaDelivery.read(session.id, delivery["id"])

        name = "FishAudio result 🎧.#{format}"
        audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: name)
        spoken = "(spoken) Ordinary FishAudio #{label}."

        native = %{
          is_error: false,
          content: [%{type: "text", text: spoken}],
          details: %{
            "provider" => "fish-audio",
            "audioPath" => descriptor["uri"],
            "media" => %{"mediaUrl" => descriptor["uri"], "trustedLocalMedia" => true},
            "mediaDescriptor" => descriptor,
            "mediaDelivery" => delivery
          }
        }

        assert {:ok, result} =
                 ResultProjection.to_part("ordinary-fish-audio-#{label}", native,
                   tool_name: "synapsis::tts"
                 )

        assert result.content == spoken
        assert result.projection["result"]["details"] == native.details
        expected_audio = %{type: "audio", descriptor: descriptor, delivery: delivery, name: name}

        expected_result = %{
          type: "tool_result",
          tool_use_id: result.tool_use_id,
          content: spoken,
          is_error: false,
          projection: result.projection
        }

        {[audio, result], [expected_audio, expected_result]}
      end)
      |> Enum.unzip()

    parts = List.flatten(parts)
    expected = List.flatten(expected)

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session.id,
      role: "assistant",
      parts: parts
    }

    assert :ok =
             Store.commit_turn(session.id, 0, Message.encode(message), Session.to_meta(session))

    assert {:ok, turn} = Store.get_turn(session.id, 0)
    assert turn.parts == expected

    for part <- parts do
      assert {:ok, dump} = Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Part.load()
    end

    response = build_conn() |> get("/api/sessions/#{session.id}") |> json_response(200)
    assert [%{"id" => id, "parts" => serialized}] = response["data"]["messages"]
    assert id == message.id
    assert serialized == expected |> Jason.encode!() |> Jason.decode!()
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: [%{parts: ^expected}]}, _} =
             join(socket, "session:#{session.id}", %{})

    # This is actual REST/channel data for the parent's shared-consumer browser
    # checks. Native Worker projections are separately exported by agent tests.
    File.write!(
      "/tmp/synapsis-fish332-evidence/server-history-projection.json",
      Jason.encode!(%{rest: serialized, channel: expected}, pretty: true)
    )
  end

  defp descriptor(format, bytes) do
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    %{
      "uri" => "synapsis-media://audio/#{sha}.#{format}",
      "sha256" => sha,
      "byte_size" => byte_size(bytes),
      "mime_type" =>
        %{"mp3" => "audio/mpeg", "opus" => "audio/ogg", "pcm" => "application/octet-stream"}[
          format
        ],
      "format" => format
    }
  end

  defp invocation(label) do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-fish-audio-#{label}",
      tool_name: "synapsis::tts"
    }
  end

  defp get_audio(port, path, mime) do
    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: @timeout]
             )

    try do
      assert {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [{"accept", mime}], nil)
      receive_response(conn, ref, System.monotonic_time(:millisecond) + @timeout, nil, [], [])
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_response(conn, ref, deadline, status, headers, body) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "timed out waiting for ordinary audio delivery"
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, remaining)

    {status, headers, body} =
      Enum.reduce(responses, {status, headers, body}, fn
        {:status, ^ref, value}, {_status, headers, body} -> {value, headers, body}
        {:headers, ^ref, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, ^ref, value}, {status, headers, body} -> {status, headers, [body, value]}
        _, acc -> acc
      end)

    if {:done, ref} in responses,
      do: {status, headers, IO.iodata_to_binary(body)},
      else: receive_response(conn, ref, deadline, status, headers, body)
  end
end
