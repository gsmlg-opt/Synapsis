defmodule Synapsis.Provider.Speech.ElevenLabsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.ElevenLabs

  @voice "pMsXgVXv3BLzUgSXRplE"
  @other_voice "a123456789b123456789"
  @audio Path.expand("../../../fixtures/speech/tone.mp3", __DIR__)
  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/elevenlabs-speech.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "ordinary defaults build the complete ElevenLabs file synthesis request" do
    assert {:ok, built} =
             ElevenLabs.build_request(%{text: "Ordinary speech", target: :audio_file}, %{
               api_key: "ordinary-fixture"
             })

    assert built.url ==
             "https://api.elevenlabs.io/v1/text-to-speech/#{@voice}?output_format=mp3_44100_128"

    assert built.body == %{
             "text" => "Ordinary speech",
             "model_id" => "eleven_multilingual_v2",
             "voice_settings" => %{
               "stability" => 0.5,
               "similarity_boost" => 0.75,
               "style" => 0,
               "use_speaker_boost" => true,
               "speed" => 1
             }
           }

    assert built.timeout_ms == 30_000
    assert built.max_bytes == 16 * 1024 * 1024
    assert built.output_format == "mp3_44100_128"
    assert built.file_extension == ".mp3"
    assert built.voice_compatible == false
    assert built.media_format == "mp3"
  end

  test "configured voice settings merge with invocation overrides and model aliases" do
    config = %{
      api_key: "ordinary-fixture",
      base_url: "https://speech.example/proxy///",
      voice_id: " #{@voice} ",
      model_id: "eleven_turbo_v2_5",
      seed: 0,
      apply_text_normalization: "on",
      language_code: "en",
      voice_settings: %{
        stability: 0.2,
        similarity_boost: 0.6,
        style: 0.3,
        use_speaker_boost: false,
        speed: 0.8
      }
    }

    assert {:ok, configured} =
             ElevenLabs.build_request(%{text: "Configured", target: :audio_file}, config)

    assert configured.body["model_id"] == "eleven_flash_v2_5"
    assert configured.body["seed"] == 0
    assert configured.body["language_code"] == "en"
    assert configured.body["apply_text_normalization"] == "on"

    persisted = %{
      config
      | voice_settings:
          Map.new(config.voice_settings, fn {key, value} -> {to_string(key), value} end),
        language_code: " EN ",
        apply_text_normalization: " ON "
    }

    assert {:ok, from_persisted} =
             ElevenLabs.build_request(%{text: "Configured", target: :audio_file}, persisted)

    assert from_persisted.body == configured.body

    request = %{
      text: "Overridden",
      target: :audio_file,
      timeout_ms: 1_234,
      provider_overrides: %{
        voice_id: @other_voice,
        model_id: "eleven_turbo_v2",
        seed: 42,
        apply_text_normalization: "off",
        language_code: "de",
        voice_settings: %{stability: 0.4, speed: 1.25}
      }
    }

    assert {:ok, built} = ElevenLabs.build_request(request, config)

    assert built.url ==
             "https://speech.example/proxy/v1/text-to-speech/#{@other_voice}?output_format=mp3_44100_128"

    assert built.body == %{
             "text" => "Overridden",
             "model_id" => "eleven_flash_v2",
             "seed" => 42,
             "apply_text_normalization" => "off",
             "language_code" => "de",
             "voice_settings" => %{
               "stability" => 0.4,
               "similarity_boost" => 0.6,
               "style" => 0.3,
               "use_speaker_boost" => false,
               "speed" => 1.25
             }
           }

    assert built.timeout_ms == 1_234
    assert config.voice_settings.stability == 0.2
    assert request.provider_overrides.voice_settings == %{stability: 0.4, speed: 1.25}
  end

  test "file output retains vendor formats and exposes only supported native media families" do
    for {format, extension, compatible, media_format} <- [
          {"mp3_44100_128", ".mp3", false, "mp3"},
          {"opus_48000_64", ".opus", true, "opus"},
          {"wav_44100", ".wav", false, "wav"},
          {"pcm_22050", ".pcm", false, nil},
          {"ulaw_8000", ".ulaw", false, nil},
          {"alaw_8000", ".alaw", false, nil}
        ] do
      assert {:ok, built} =
               ElevenLabs.build_request(
                 %{
                   text: "Format",
                   target: :audio_file,
                   provider_overrides: %{output_format: format}
                 },
                 %{api_key: "ordinary-fixture"}
               )

      assert URI.decode_query(URI.parse(built.url).query) == %{"output_format" => format}
      assert built.output_format == format
      assert built.file_extension == extension
      assert built.voice_compatible == compatible
      assert built[:media_format] == media_format
    end

    assert {:ok, voice_note} =
             ElevenLabs.build_request(%{text: "Voice note", target: :voice_note}, %{
               api_key: "ordinary-fixture"
             })

    assert voice_note.output_format == "opus_48000_64"
    assert voice_note.voice_compatible == true
  end

  test "latency tier zero is retained and Eleven v3 omits the latency query" do
    for {model, expected} <- [
          {"eleven_multilingual_v2",
           %{"output_format" => "mp3_44100_128", "optimize_streaming_latency" => "0"}},
          {"eleven_v3", %{"output_format" => "mp3_44100_128"}}
        ] do
      assert {:ok, built} =
               ElevenLabs.build_request(
                 %{
                   text: "Latency",
                   target: :audio_file,
                   provider_overrides: %{model_id: model, latency_tier: 0}
                 },
                 %{api_key: "ordinary-fixture"}
               )

      assert URI.decode_query(URI.parse(built.url).query) == expected
      assert built.body["model_id"] == model
    end
  end

  test "synthesis posts the complete default request and preserves MP3 bytes at the exact bound",
       ctx do
    audio = File.read!(@audio)
    stub(ctx, @voice, audio, "audio/mpeg")

    assert {:ok, response} =
             ElevenLabs.synthesize(%{text: "Ordinary speech", target: :audio_file}, %{
               api_key: "ordinary-fixture",
               base_url: Gaoxy.Test.url(ctx.fixture, "/proxy/"),
               max_bytes: byte_size(audio)
             })

    assert_receive {:http, body, query, headers}
    assert body["text"] == "Ordinary speech"
    assert body["model_id"] == "eleven_multilingual_v2"
    assert body["voice_settings"]["similarity_boost"] == 0.75
    assert query == %{"output_format" => "mp3_44100_128"}
    assert Map.new(headers)["accept"] == "audio/mpeg"
    assert Map.new(headers)["content-type"] == "application/json"

    assert response == %{
             audio: audio,
             output_format: "mp3_44100_128",
             file_extension: ".mp3",
             voice_compatible: false,
             media_format: "mp3"
           }
  end

  test "ordinary opaque PCM synthesis preserves the vendor format without native publication",
       ctx do
    audio = <<0::little-signed-16, 100::little-signed-16, -100::little-signed-16>>
    stub(ctx, @other_voice, audio, "audio/pcm")

    assert {:ok, response} =
             ElevenLabs.synthesize(
               %{
                 text: "PCM",
                 target: :audio_file,
                 timeout_ms: 2_000,
                 provider_overrides: %{
                   voice_id: @other_voice,
                   output_format: "pcm_22050",
                   latency_tier: 2
                 }
               },
               %{
                 api_key: "ordinary-fixture",
                 base_url: Gaoxy.Test.url(ctx.fixture, "/proxy"),
                 max_bytes: byte_size(audio)
               }
             )

    assert_receive {:http, %{"text" => "PCM"}, query, _headers}

    assert query == %{
             "output_format" => "pcm_22050",
             "optimize_streaming_latency" => "2"
           }

    assert response.audio == audio
    assert response.output_format == "pcm_22050"
    assert response.file_extension == ".pcm"
    assert response.voice_compatible == false
    assert response[:media_format] == nil
  end

  test "all 31 pinned synthesis callbacks preserve complete requests, metadata and HTTP bytes" do
    reference = @reference |> File.read!() |> Jason.decode!()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert reference["counts"]["synthesisCallbacks"] == 31
    assert length(reference["observations"]) == 31

    for observation <- reference["observations"] do
      input = observation["input"]
      source_request = observation["request"]
      config = source_options(get_in(input, ["rawConfig", "providers", "elevenlabs"]))

      request = %{
        text: input["text"],
        target: if(input["target"] == "voice-note", do: :voice_note, else: :audio_file),
        timeout_ms: input["timeoutMs"],
        provider_overrides: source_options(input["providerOverrides"] || %{})
      }

      expected = source_result(observation["result"])
      assert {:ok, built} = ElevenLabs.build_request(request, config)
      assert built.url == source_request["url"], observation["id"]
      assert built.body == source_request["body"], observation["id"]
      assert built.timeout_ms == source_request["timeoutMs"]
      assert built.max_bytes == 16 * 1024 * 1024

      assert Map.take(built, [:output_format, :file_extension, :voice_compatible, :media_format]) ==
               Map.delete(expected, :audio),
             observation["id"]

      fixture = Gaoxy.Test.open()

      try do
        owner = self()
        token = make_ref()
        uri = URI.parse(source_request["url"])

        Gaoxy.Test.stub(fixture, "POST", uri.path, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:source_http, token, conn.method, conn.request_path, conn.query_string,
             Jason.decode!(body), Map.new(conn.req_headers)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("audio/mpeg")
          |> Plug.Conn.resp(200, expected.audio)
        end)

        base =
          config
          |> Map.get(:base_url, "https://api.elevenlabs.io")
          |> String.trim()
          |> URI.parse()

        local_config = Map.put(config, :base_url, Gaoxy.Test.url(fixture, base.path || "/"))
        assert {:ok, local_built} = ElevenLabs.build_request(request, local_config)
        assert local_built.url == Gaoxy.Test.url(fixture, uri.path) <> "?" <> uri.query
        assert local_built.body == built.body

        assert {:ok, result} = ElevenLabs.synthesize(request, local_config)
        assert result == expected, observation["id"]
        assert_receive {:source_http, ^token, method, path, query, body, headers}
        assert method == source_request["method"]
        assert path == source_request["path"]
        assert query == uri.query
        assert body == source_request["body"]

        expected_headers =
          Map.new(source_request["headers"], fn {key, value} ->
            {String.downcase(key), value}
          end)

        assert Map.take(headers, ~w(xi-api-key content-type accept)) == expected_headers,
               observation["id"]
      after
        Gaoxy.Test.close(fixture)
      end

      assert input == observation["inputAfter"]
    end
  end

  defp source_options(options) do
    for {source, target} <- [
          {"apiKey", :api_key},
          {"baseUrl", :base_url},
          {"voiceId", :voice_id},
          {"modelId", :model_id},
          {"seed", :seed},
          {"applyTextNormalization", :apply_text_normalization},
          {"languageCode", :language_code},
          {"voiceSettings", :voice_settings},
          {"outputFormat", :output_format},
          {"latencyTier", :latency_tier}
        ],
        Map.has_key?(options, source),
        into: %{} do
      value = options[source]

      value =
        if target == :voice_settings do
          for {source, target} <- [
                {"stability", :stability},
                {"similarityBoost", :similarity_boost},
                {"style", :style},
                {"useSpeakerBoost", :use_speaker_boost},
                {"speed", :speed}
              ],
              Map.has_key?(value, source),
              into: %{},
              do: {target, value[source]}
        else
          value
        end

      {target, value}
    end
  end

  defp source_result(result) do
    family = String.trim_leading(result["fileExtension"], ".")

    expected = %{
      audio: Base.decode64!(result["audioBase64"]),
      output_format: result["outputFormat"],
      file_extension: result["fileExtension"],
      voice_compatible: result["voiceCompatible"]
    }

    if family in ~w(mp3 opus wav), do: Map.put(expected, :media_format, family), else: expected
  end

  defp stub(ctx, voice, audio, content_type) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/proxy/v1/text-to-speech/" <> voice, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(owner, {
        :http,
        Jason.decode!(body),
        URI.decode_query(conn.query_string),
        conn.req_headers
      })

      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(200, audio)
    end)
  end
end
