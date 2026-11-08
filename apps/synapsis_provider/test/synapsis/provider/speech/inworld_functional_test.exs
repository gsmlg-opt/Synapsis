defmodule Synapsis.Provider.Speech.InworldFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.Inworld

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/inworld-speech.json",
               __DIR__
             )

  # Literal ordinary contract from OpenClaw 488631c extensions/inworld/{tts,
  # speech-provider}.ts and packages/media-core/src/base64.ts.
  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "defaults build the complete buffered Inworld synthesis request" do
    assert {:ok, built} =
             Inworld.build_request(%{text: "Ordinary speech 雪", target: :audio_file}, %{
               api_key: "ordinary-speech-fixture"
             })

    assert built.url == "https://api.inworld.ai/tts/v1/voice:stream"
    assert built.body == body("Ordinary speech 雪", "Sarah", "inworld-tts-1.5-max", "MP3")
    assert built.timeout_ms == 30_000
    assert built.max_bytes == 16 * 1024 * 1024
    assert built.max_response_bytes == 32 * 1024 * 1024
    assert built.output_format == "mp3"
    assert built.file_extension == ".mp3"
    assert built.voice_compatible == false
    assert built[:sample_rate] == nil
  end

  test "configured voice model temperature and versioned custom prefix are preserved" do
    assert {:ok, built} =
             Inworld.build_request(%{text: "Configured speech", target: :audio_file}, %{
               api_key: "ordinary-speech-fixture",
               base_url: " https://speech.example/custom/api/v7/// ",
               voice_id: "\u00A0\uFEFF Ashley \uFEFF\u00A0",
               model_id: "\uFEFF\u00A0 inworld-tts-1.5-mini \u00A0\uFEFF",
               temperature: 0.85,
               max_bytes: 4096
             })

    assert built.url == "https://speech.example/custom/api/v7/tts/v1/voice:stream"

    assert built.body ==
             Map.put(
               body("Configured speech", "Ashley", "inworld-tts-1.5-mini", "MP3"),
               "temperature",
               0.85
             )

    assert built.max_bytes == 4096
    assert built.max_response_bytes == 8192
    assert built.output_format == "mp3"
    assert built.file_extension == ".mp3"
    assert built.voice_compatible == false
  end

  test "invocation voice model and temperature override config without changing either input" do
    config = %{
      api_key: "ordinary-speech-fixture",
      voice_id: "Sarah",
      model_id: "inworld-tts-1.5-max",
      temperature: 0.9
    }

    request = %{
      text: "Invocation speech",
      target: :audio_file,
      timeout_ms: 4321,
      provider_overrides: %{
        voice_id: " Ashley ",
        model_id: " inworld-tts-1.5-mini ",
        temperature: 1.2
      }
    }

    assert {:ok, built} = Inworld.build_request(request, config)

    assert built.body ==
             Map.put(
               body("Invocation speech", "Ashley", "inworld-tts-1.5-mini", "MP3"),
               "temperature",
               1.2
             )

    assert built.timeout_ms == 4321
    assert config.voice_id == "Sarah"
    assert config.model_id == "inworld-tts-1.5-max"
    assert config.temperature == 0.9

    assert request.provider_overrides == %{
             voice_id: " Ashley ",
             model_id: " inworld-tts-1.5-mini ",
             temperature: 1.2
           }
  end

  for {target, encoding, expected_metadata} <- [
        {:audio_file, "MP3",
         %{output_format: "mp3", file_extension: ".mp3", voice_compatible: false}},
        {:voice_note, "OGG_OPUS",
         %{output_format: "ogg_opus", file_extension: ".ogg", voice_compatible: true}},
        {:telephony, "PCM", %{output_format: "pcm", sample_rate: 22_050}}
      ] do
    @target target
    @encoding encoding
    @expected_metadata expected_metadata
    test "#{target} preserves ordered opaque audio across ordinary NDJSON records", ctx do
      # Transport fidelity only: no decoding or codec conversion is claimed.
      audio = <<0, 255, 128, 1, 13, 10, 0, 254, 42>>

      expected =
        body("Opaque speech", "Ashley", "inworld-tts-1.5-mini", @encoding)
        |> Map.put("temperature", 1.1)
        |> then(fn request ->
          if @target == :telephony,
            do: put_in(request, ["audioConfig", "sampleRateHertz"], 22_050),
            else: request
        end)

      ndjson =
        "\n  " <>
          Jason.encode!(%{"result" => %{"audioContent" => " AP+ A \r\n"}}) <>
          "\r\n" <>
          Jason.encode!(%{"metadata" => %{"requestId" => "ordinary"}}) <>
          "\n\n" <>
          Jason.encode!(%{"result" => %{"audioContent" => "AQ0KAP4"}}) <>
          "\n" <>
          Jason.encode!(%{"result" => %{"audioContent" => "Kg=="}}) <> "\n"

      expect_ndjson(ctx.fixture, "/custom/v7/tts/v1/voice:stream", expected, ndjson)

      request = %{text: "Opaque speech", target: @target, timeout_ms: 5000}

      config = %{
        api_key: "ordinary-speech-fixture",
        base_url: Gaoxy.Test.url(ctx.fixture, "/custom/v7///"),
        voice_id: "Ashley",
        model_id: "inworld-tts-1.5-mini",
        temperature: 1.1,
        max_bytes: 4096
      }

      assert {:ok, built} = Inworld.build_request(request, config)
      assert built.body == expected
      assert built.timeout_ms == 5000

      for field <- [:output_format, :file_extension, :voice_compatible, :sample_rate],
          do: assert(built[field] == @expected_metadata[field])

      assert {:ok, result} = Inworld.synthesize(request, config)
      assert result == Map.put(@expected_metadata, :audio, audio)

      assert_receive {:inworld_speech_http, "POST", "/custom/v7/tts/v1/voice:stream", "",
                      ^expected},
                     1000
    end
  end

  test "ordinary distinct deadlines use a linked task and reuse the shared Finch pool", ctx do
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
    expected = body("Shared pool", "Sarah", "inworld-tts-1.5-max", "MP3")

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/tts/v1/voice:stream", fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      send(owner, {:pool_body, Jason.decode!(data)})
      Plug.Conn.resp(conn, 200, Jason.encode!(%{result: %{audioContent: Base.encode64(audio)}}))
    end)

    for timeout <- [1001, 2002, 3003] do
      request = %{text: "Shared pool", target: :audio_file, timeout_ms: timeout}
      config = %{api_key: "ordinary-speech-fixture", base_url: url}
      assert {:ok, built} = Inworld.build_request(request, config)
      assert built.timeout_ms == timeout
      assert {:ok, %{audio: ^audio}} = Inworld.synthesize(request, config)
      assert_receive {:pool_body, ^expected}, 1000
      assert_receive {:inworld_pool, Req.Finch, transport, links}, 1000
      refute transport == owner
      assert owner in links
    end
  end

  test "every pinned observation matches requests metadata and actual NDJSON HTTP bytes" do
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
        provider_overrides: source_overrides(input["providerOverrides"] || %{})
      }

      expected = source_result(row["result"])
      assert {:ok, built} = Inworld.build_request(request, config)
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert built.max_bytes == 16 * 1024 * 1024
      assert built.max_response_bytes == 32 * 1024 * 1024

      for field <- [:output_format, :file_extension, :voice_compatible, :sample_rate],
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
            {:inworld_source_http, token, conn.method, conn.request_path,
             URI.decode_query(conn.query_string), Jason.decode!(data), Map.new(conn.req_headers)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.resp(row["response"]["status"], row["response"]["ndjson"])
        end)

        assert {:ok, local_built} = Inworld.build_request(request, local)
        assert local_built.url == Gaoxy.Test.url(fixture, uri.path)
        assert local_built.body == built.body
        assert {:ok, result} = Inworld.synthesize(request, local)
        assert result == expected, row["id"]
        assert_receive {:inworld_source_http, ^token, method, path, query, body, headers}, 1000
        assert method == row["request"]["method"]
        assert path == row["request"]["path"]
        assert query == row["request"]["query"]
        assert body == row["request"]["body"]
        assert headers["content-type"] == row["request"]["headers"]["Content-Type"]
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
          {"modelId", :model_id},
          {"temperature", :temperature}
        ],
        Map.has_key?(options, source),
        into: %{},
        do: {target, options[source]}
  end

  defp source_target("audio-file"), do: :audio_file
  defp source_target("voice-note"), do: :voice_note
  defp source_target("telephony"), do: :telephony

  defp source_overrides(options) do
    options
    |> source_options()
    |> then(fn mapped ->
      for {primary, alternate, target} <- [
            {"voiceId", "voice", :voice_id},
            {"modelId", "model", :model_id}
          ],
          Map.has_key?(options, primary) or Map.has_key?(options, alternate),
          reduce: mapped do
        acc ->
          value = if is_nil(options[primary]), do: options[alternate], else: options[primary]
          Map.put(acc, target, value)
      end
    end)
  end

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
      %{name: name, request: %{port: ^port, path: "/v1/tts/v1/voice:stream"}} ->
        {:links, links} = Process.info(self(), :links)
        send(owner, {:inworld_pool, name, self(), links})

      _ ->
        :ok
    end
  end

  defp body(text, voice, model, encoding),
    do: %{
      "text" => text,
      "voiceId" => voice,
      "modelId" => model,
      "audioConfig" => %{"audioEncoding" => encoding}
    }

  defp expect_ndjson(fixture, path, expected, ndjson) do
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(data)
      assert decoded == expected
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      send(
        owner,
        {:inworld_speech_http, conn.method, conn.request_path, conn.query_string, decoded}
      )

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_chunked(200)

      # Split inside the first JSON record; HTTP chunks are not NDJSON lines.
      <<first::binary-size(19), rest::binary>> = ndjson
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)
  end
end
