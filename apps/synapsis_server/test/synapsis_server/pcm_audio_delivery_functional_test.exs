defmodule SynapsisServer.PCMAudioDeliveryFunctionalTest do
  use SynapsisServer.ChannelCase
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.{Message, Part, Session}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @timeout 5_000
  @audio <<0, 255, 128, "ordinary opaque PCM endpoint", 0, 254>>

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

  test "actual Endpoint downloads exact PCM repeatedly and REST/channel preserve its Concord part",
       %{tmp_dir: root, port: port} do
    session = %Session{
      id: Ecto.UUID.generate(),
      provider: "ordinary-pcm-fixture",
      model: "fixture"
    }

    assert :ok = Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    media_root = Path.join(root, "original-pcm-root")
    assert {:ok, descriptor} = Media.put_audio(@audio, "pcm", root: media_root)
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    assert descriptor == %{
             "uri" => "synapsis-media://audio/#{sha}.pcm",
             "sha256" => sha,
             "byte_size" => byte_size(@audio),
             "format" => "pcm",
             "mime_type" => "application/octet-stream"
           }

    assert {:ok, delivery} =
             MediaDelivery.publish(descriptor, session.id, invocation(),
               root: media_root,
               max_bytes: 4_096
             )

    assert {:ok, path} = MediaDelivery.url(delivery)
    assert [file] = Path.wildcard(Path.join(media_root, "**/*.pcm"))
    original = File.stat!(file, time: :posix)

    for _ <- 1..2 do
      {status, headers, body} = get_audio(port, path, "application/octet-stream")
      assert status == 200
      assert {"content-type", "application/octet-stream"} in headers
      assert {"content-length", Integer.to_string(byte_size(@audio))} in headers
      assert {"content-disposition", "attachment; filename=\"audio.pcm\""} in headers
      assert body == @audio
    end

    current = File.stat!(file, time: :posix)

    assert {current.inode, current.mtime, current.size} ==
             {original.inode, original.mtime, original.size}

    audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: "Ordinary 🎧.pcm")

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session.id,
      role: "assistant",
      parts: [audio]
    }

    assert :ok =
             Store.commit_turn(session.id, 0, Message.encode(message), Session.to_meta(session))

    expected = %{
      type: "audio",
      descriptor: descriptor,
      delivery: delivery,
      name: "Ordinary 🎧.pcm"
    }

    response = build_conn() |> get("/api/sessions/#{session.id}") |> json_response(200)
    assert [%{"id" => message_id, "parts" => [serialized]}] = response["data"]["messages"]
    assert message_id == message.id
    assert serialized == expected |> Jason.encode!() |> Jason.decode!()
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: [%{parts: [^expected]}]}, _} =
             join(socket, "session:#{session.id}", %{})

    assert {:ok, %{audio: @audio, descriptor: ^descriptor}} =
             MediaDelivery.read(session.id, delivery["id"])
  end

  defp invocation do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-audio-http",
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
    assert remaining > 0, "timed out waiting for audio delivery"
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
