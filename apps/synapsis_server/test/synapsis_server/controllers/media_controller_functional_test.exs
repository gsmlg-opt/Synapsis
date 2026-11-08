defmodule SynapsisServer.MediaControllerFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @timeout 5_000
  @fixtures Path.expand("../../../../synapsis_provider/test/fixtures/speech", __DIR__)
  @mp3 File.read!(Path.join(@fixtures, "tone.mp3"))
  @opus File.read!(Path.join(@fixtures, "tone.opus"))
  @wav <<"RIFF", 38::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
         8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 2::little-32,
         0::little-16>>

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

  test "the actual Endpoint conserves WAV, MP3 and Opus bytes from original default and custom roots",
       %{tmp_dir: root, port: port} do
    for {format, mime, bytes, opts} <- [
          {"wav", "audio/wav", @wav, []},
          {"mp3", "audio/mpeg", @mp3,
           [root: Path.join(root, "custom-mp3"), max_bytes: byte_size(@mp3)]},
          {"opus", "audio/ogg", @opus,
           [root: Path.join(root, "custom-opus"), max_bytes: byte_size(@opus)]}
        ] do
      media_root =
        Keyword.get(opts, :root, Path.join(Synapsis.Config.Store.config_dir(), "media"))

      sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      <<first::binary-size(2), second::binary-size(2), rest::binary>> = sha256
      file = Path.join([media_root, first, second, rest <> "." <> format])
      existed = File.exists?(file)
      assert {:ok, descriptor} = Media.put_audio(bytes, format, opts)

      assert descriptor == %{
               "uri" => "synapsis-media://audio/#{sha256}.#{format}",
               "sha256" => sha256,
               "byte_size" => byte_size(bytes),
               "mime_type" => mime,
               "format" => format
             }

      max_bytes = Keyword.get(opts, :max_bytes, 16 * 1024 * 1024)
      session_id = Ecto.UUID.generate()

      assert {:ok, ref} =
               MediaDelivery.publish(descriptor, session_id, invocation(),
                 root: media_root,
                 max_bytes: max_bytes
               )

      assert {:ok, path} = MediaDelivery.url(ref)
      before = File.stat!(file, time: :posix)
      unless existed, do: on_exit(fn -> File.rm(file) end)

      for _ <- 1..2 do
        {status, headers, body} = get_audio(port, path, mime)
        assert status == 200
        assert {"content-type", mime} in headers
        assert {"content-length", Integer.to_string(byte_size(bytes))} in headers
        assert {"content-disposition", "inline; filename=\"audio.#{format}\""} in headers
        assert body == bytes
      end

      after_read = File.stat!(file, time: :posix)

      assert {after_read.inode, after_read.mtime, after_read.size} ==
               {before.inode, before.mtime, before.size}
    end
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
