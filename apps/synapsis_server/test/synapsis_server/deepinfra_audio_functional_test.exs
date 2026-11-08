defmodule SynapsisServer.DeepInfraAudioFunctionalTest do
  use SynapsisServer.ChannelCase
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias Synapsis.{Message, Part, Session}

  @moduletag :tmp_dir
  @timeout 5_000
  # Deliberately opaque fixtures; MIME and byte conservation do not prove decoding.
  @formats [
    {"mp3", "audio/mpeg", <<255, 251, "ordinary endpoint MP3", 0>>},
    {"opus", "audio/ogg", <<"OggS", 0, "ordinary endpoint Opus", 255>>},
    {"flac", "audio/flac", <<"fLaC", 0, "ordinary endpoint FLAC", 254>>},
    {"wav", "audio/wav", <<"RIFF", 0, "ordinary endpoint WAV", 128>>},
    {"pcm", "application/octet-stream", <<0, 255, "ordinary endpoint PCM", 0>>}
  ]

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

  test "actual Endpoint conserves FLAC inline and PCM attachment from original durable facts",
       %{tmp_dir: root, port: port} do
    for {format, mime, bytes} <- Enum.filter(@formats, &(elem(&1, 0) in ["flac", "pcm"])) do
      media_root = Path.join(root, "original-#{format}")
      expected = descriptor(format, mime, bytes)
      assert {:ok, ^expected} = Media.put_audio(bytes, format, root: media_root)
      session_id = Ecto.UUID.generate()

      assert {:ok, reference} =
               MediaDelivery.publish(expected, session_id, invocation(),
                 root: media_root,
                 max_bytes: 4_096
               )

      assert {:ok, path} = MediaDelivery.url(reference)
      assert [file] = Path.wildcard(Path.join(media_root, "**/*.#{format}"))
      original = File.stat!(file, time: :posix)
      disposition = if format == "pcm", do: "attachment", else: "inline"

      for _ <- 1..2 do
        {status, headers, body} = get_audio(port, path, mime)
        assert status == 200
        assert {"content-type", mime} in headers
        assert {"content-length", Integer.to_string(byte_size(bytes))} in headers

        assert {"content-disposition", "#{disposition}; filename=\"audio.#{format}\""} in headers

        assert body == bytes
        assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == expected["sha256"]
      end

      assert {:ok, %{audio: ^bytes, descriptor: ^expected}} =
               MediaDelivery.read(session_id, reference["id"])

      current = File.stat!(file, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end
  end

  test "REST and channel history preserve all five Audio Parts with actual original-root references",
       %{tmp_dir: root} do
    session = %Session{
      id: Ecto.UUID.generate(),
      provider: "deepinfra-audio-history-fixture",
      model: "fixture"
    }

    assert :ok = Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    {parts, expected} =
      Enum.map(@formats, fn {format, mime, bytes} ->
        media_root = Path.join(root, "history-#{format}")
        descriptor = descriptor(format, mime, bytes)
        assert {:ok, ^descriptor} = Media.put_audio(bytes, format, root: media_root)

        assert {:ok, delivery} =
                 MediaDelivery.publish(descriptor, session.id, invocation(),
                   root: media_root,
                   max_bytes: 4_096
                 )

        assert {:ok, %{audio: ^bytes, descriptor: ^descriptor}} =
                 MediaDelivery.read(session.id, delivery["id"])

        name = "Result 🎧.#{format}"
        part = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: name)
        expected = %{type: "audio", descriptor: descriptor, delivery: delivery, name: name}
        {part, expected}
      end)
      |> Enum.unzip()

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
    response = build_conn() |> get("/api/sessions/#{session.id}") |> json_response(200)
    assert [%{"id" => id, "parts" => serialized}] = response["data"]["messages"]
    assert id == message.id
    assert serialized == expected |> Jason.encode!() |> Jason.decode!()
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: [%{parts: ^expected}]}, _} =
             join(socket, "session:#{session.id}", %{})
  end

  defp descriptor(format, mime, bytes) do
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    %{
      "uri" => "synapsis-media://audio/#{sha}.#{format}",
      "sha256" => sha,
      "byte_size" => byte_size(bytes),
      "mime_type" => mime,
      "format" => format
    }
  end

  defp invocation do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-deepinfra-audio",
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
