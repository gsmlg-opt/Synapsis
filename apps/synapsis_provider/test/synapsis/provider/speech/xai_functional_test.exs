defmodule Synapsis.Provider.Speech.XAIFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.XAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/xai-speech.json",
               __DIR__
             )

  # Literal ordinary contract from OpenClaw 488631c extensions/xai/tts.ts and
  # speech-provider{,-metadata-factory}.ts; no production-derived expectations.
  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "defaults build the complete buffered xAI synthesis request" do
    assert {:ok, built} =
             XAI.build_request(%{text: "Ordinary speech 雪", target: :audio_file}, %{
               api_key: "ordinary-speech-fixture"
             })

    assert built.url == "https://api.x.ai/v1/tts"
    assert built.body == body("Ordinary speech 雪", "eve", "en", "mp3")
    assert built.timeout_ms == 30_000
    assert built.max_bytes == 16 * 1024 * 1024
    assert built.output_format == "mp3"
    assert built.file_extension == ".mp3"
    assert built.voice_compatible == false
    assert built[:sample_rate] == nil
  end

  test "configured voice language speed and versioned custom prefix are preserved" do
    assert {:ok, built} =
             XAI.build_request(%{text: "Configured speech", target: :audio_file}, %{
               api_key: "ordinary-speech-fixture",
               base_url: " https://speech.example/custom/api/v7/// ",
               voice_id: " custom-voice ",
               language: " PT-BR ",
               speed: 0.85,
               response_format: " WAV ",
               max_bytes: 4096
             })

    assert built.url == "https://speech.example/custom/api/v7/tts"

    assert built.body ==
             Map.put(body("Configured speech", "custom-voice", "pt-br", "wav"), "speed", 0.85)

    assert built.max_bytes == 4096
    assert built.output_format == "wav"
    assert built.file_extension == ".wav"
    assert built.voice_compatible == false
  end

  test "invocation voice language and speed override config without changing either input" do
    config = %{
      api_key: "ordinary-speech-fixture",
      voice_id: "eve",
      language: "en",
      speed: 0.9,
      response_format: "wav"
    }

    request = %{
      text: "Invocation speech",
      target: :audio_file,
      timeout_ms: 4321,
      provider_overrides: %{voice_id: " rex ", language: " ZH-CN ", speed: 1.2}
    }

    assert {:ok, built} = XAI.build_request(request, config)

    assert built.body ==
             Map.put(body("Invocation speech", "rex", "zh-cn", "wav"), "speed", 1.2)

    assert built.timeout_ms == 4321
    assert config.voice_id == "eve"
    assert config.language == "en"
    assert config.speed == 0.9
    assert request.provider_overrides == %{voice_id: " rex ", language: " ZH-CN ", speed: 1.2}
  end

  test "configured ordinary language forms and speeds are forwarded" do
    for {language, normalized, speed} <- [
          {"auto", "auto", 1},
          {" FR ", "fr", 0.8},
          {" fil ", "fil", 1.25},
          {" zh-HANT ", "zh-hant", 1.1}
        ] do
      assert {:ok, built} =
               XAI.build_request(%{text: "Language", target: :audio_file}, %{
                 api_key: "ordinary-speech-fixture",
                 language: language,
                 speed: speed
               })

      assert built.body == Map.put(body("Language", "eve", normalized, "mp3"), "speed", speed)
    end
  end

  for format <- ~w(mp3 wav pcm mulaw alaw) do
    @format format
    test "#{format} posts the exact ordinary request and preserves all opaque audio bytes", ctx do
      # Transport fidelity only: no decoding or codec conversion is claimed.
      audio = <<0, 255, 128, 1, 13, 10, 0, 254, 42>>
      expected = Map.put(body("Opaque speech", "sal", "de", @format), "speed", 1.1)
      expect_audio(ctx.fixture, "/custom/v7/tts", expected, audio)

      assert {:ok, result} =
               XAI.synthesize(%{text: "Opaque speech", target: :audio_file, timeout_ms: 5000}, %{
                 api_key: "ordinary-speech-fixture",
                 base_url: Gaoxy.Test.url(ctx.fixture, "/custom/v7///"),
                 voice_id: "sal",
                 language: "de",
                 speed: 1.1,
                 response_format: @format,
                 max_bytes: 4096
               })

      assert result == %{
               audio: audio,
               output_format: @format,
               file_extension: "." <> @format,
               voice_compatible: false
             }

      assert_receive {:xai_speech_http, "POST", "/custom/v7/tts", "", ^expected}, 1000
    end
  end

  test "voice notes force MP3 for every configured file format", ctx do
    audio = <<0, 128, 255, 1>>
    expected = body("Voice note", "eve", "en", "mp3")
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/tts", fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      send(owner, {:note_body, Jason.decode!(data)})
      Plug.Conn.resp(conn, 200, audio)
    end)

    for format <- ~w(mp3 wav pcm mulaw alaw) do
      assert {:ok, result} =
               XAI.synthesize(%{text: "Voice note", target: :voice_note}, %{
                 api_key: "ordinary-speech-fixture",
                 base_url: Gaoxy.Test.url(ctx.fixture, "/v1"),
                 response_format: format
               })

      assert result == %{
               audio: audio,
               output_format: "mp3",
               file_extension: ".mp3",
               voice_compatible: false
             }

      assert_receive {:note_body, ^expected}, 1000
    end
  end

  test "telephony forces PCM and returns the pinned 24 kHz metadata", ctx do
    audio = <<0::little-signed-16, 100::little-signed-16, -100::little-signed-16>>
    expected = Map.put(body("Telephone speech", "leo", "auto", "pcm"), "speed", 0.9)
    expect_audio(ctx.fixture, "/v1/tts", expected, audio)

    request = %{text: "Telephone speech", target: :telephony, timeout_ms: 2345}

    config = %{
      api_key: "ordinary-speech-fixture",
      base_url: Gaoxy.Test.url(ctx.fixture, "/v1"),
      voice_id: "leo",
      language: "auto",
      speed: 0.9,
      response_format: "wav"
    }

    assert {:ok, built} = XAI.build_request(request, config)
    assert built.body == expected
    assert built.timeout_ms == 2345
    assert built.output_format == "pcm"
    assert built.sample_rate == 24_000

    assert {:ok, %{audio: ^audio, output_format: "pcm", sample_rate: 24_000}} =
             XAI.synthesize(request, config)

    assert_receive {:xai_speech_http, "POST", "/v1/tts", "", ^expected}, 1000
  end

  test "ordinary distinct deadlines reuse the shared Finch pool", ctx do
    owner = self()
    url = Gaoxy.Test.url(ctx.fixture, "/v1")
    port = URI.parse(url).port
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:finch, :request, :start], &__MODULE__.pool_start/4, %{
        owner: owner,
        port: port
      })

    on_exit(fn -> :telemetry.detach(handler) end)
    audio = <<0, 255, 128, 1>>
    expected = body("Shared pool", "eve", "en", "mp3")

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/tts", fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      send(owner, {:pool_body, Jason.decode!(data)})
      Plug.Conn.resp(conn, 200, audio)
    end)

    for timeout <- [1001, 2002, 3003] do
      assert {:ok, built} =
               XAI.build_request(
                 %{text: "Shared pool", target: :audio_file, timeout_ms: timeout},
                 %{api_key: "ordinary-speech-fixture", base_url: url}
               )

      assert built.timeout_ms == timeout

      assert {:ok, %{audio: ^audio}} =
               XAI.synthesize(
                 %{text: "Shared pool", target: :audio_file, timeout_ms: timeout},
                 %{api_key: "ordinary-speech-fixture", base_url: url}
               )

      assert_receive {:pool_body, ^expected}, 1000
      assert_receive {:xai_pool, Req.Finch}, 1000
    end
  end

  test "every pinned buffered synthesis observation matches requests metadata and opaque HTTP bytes" do
    reference = @reference |> File.read!() |> Jason.decode!()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert [_ | _] = reference["observations"]

    for row <- reference["observations"] do
      input = row["input"]
      config = source_options(row["resolvedConfig"])

      request = %{
        text: input["text"],
        target: source_target(input["target"]),
        timeout_ms: input["timeoutMs"],
        provider_overrides: source_options(input["providerOverrides"] || %{})
      }

      expected = source_result(row["result"])
      assert {:ok, built} = XAI.build_request(request, config)
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert built.max_bytes == 16 * 1024 * 1024
      assert built.output_format == expected.output_format

      for field <- [:file_extension, :voice_compatible, :sample_rate],
          do: assert(built[field] == expected[field], row["id"])

      fixture = Gaoxy.Test.open()

      try do
        uri = URI.parse(built.url)
        base_path = URI.parse(config.base_url).path || "/"
        local = Map.put(config, :base_url, Gaoxy.Test.url(fixture, base_path))
        owner = self()
        token = make_ref()

        Gaoxy.Test.expect_once(fixture, "POST", uri.path, fn conn ->
          {:ok, data, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:xai_source_http, token, conn.method, conn.request_path,
             URI.decode_query(conn.query_string), Jason.decode!(data), Map.new(conn.req_headers)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.resp(200, expected.audio)
        end)

        assert {:ok, local_built} = XAI.build_request(request, local)
        assert local_built.url == Gaoxy.Test.url(fixture, uri.path)
        assert local_built.body == built.body
        assert {:ok, result} = XAI.synthesize(request, local)
        assert result == expected, row["id"]
        assert_receive {:xai_source_http, ^token, method, path, query, body, headers}, 1000
        assert method == row["request"]["method"]
        assert path == row["request"]["path"]
        assert query == row["request"]["query"]
        assert body == row["request"]["body"]
        assert headers["content-type"] == row["request"]["headers"]["content-type"]
      after
        Gaoxy.Test.close(fixture)
      end

      assert input == row["inputAfter"]
    end
  end

  defp source_options(options) do
    for {source, target} <- [
          {"apiKey", :api_key},
          {"baseUrl", :base_url},
          {"voiceId", :voice_id},
          {"language", :language},
          {"speed", :speed},
          {"responseFormat", :response_format}
        ],
        Map.has_key?(options, source),
        into: %{},
        do: {target, options[source]}
  end

  defp source_target("audio-file"), do: :audio_file
  defp source_target("voice-note"), do: :voice_note
  defp source_target("telephony"), do: :telephony

  defp source_result(result) do
    Enum.reduce(
      [
        {"fileExtension", :file_extension},
        {"voiceCompatible", :voice_compatible},
        {"sampleRate", :sample_rate}
      ],
      %{audio: Base.decode64!(result["audioBase64"]), output_format: result["outputFormat"]},
      fn {source, target}, expected ->
        if Map.has_key?(result, source),
          do: Map.put(expected, target, result[source]),
          else: expected
      end
    )
  end

  @doc false
  def pool_start(_event, _measurements, metadata, %{owner: owner, port: port}) do
    case metadata do
      %{name: name, request: %{port: ^port, path: "/v1/tts"}} -> send(owner, {:xai_pool, name})
      _ -> :ok
    end
  end

  defp body(text, voice, language, codec),
    do: %{
      "text" => text,
      "voice_id" => voice,
      "language" => language,
      "output_format" => %{"codec" => codec}
    }

  defp expect_audio(fixture, path, expected, audio) do
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(data)
      assert decoded == expected
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      send(owner, {:xai_speech_http, conn.method, conn.request_path, conn.query_string, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.resp(200, audio)
    end)
  end
end
