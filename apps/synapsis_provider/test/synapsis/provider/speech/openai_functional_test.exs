defmodule Synapsis.Provider.Speech.OpenAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Speech.OpenAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openai-speech.json",
               __DIR__
             )
  @ids ~w(default-file default-note file-opus note-wav file-wav groq-file groq-note configured-openai legacy-model custom-voice-model provider-overrides extra-body-fields extra-body-final-wins telephony)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "all pinned raw resolution and speech request observations match" do
    rows = observations()
    assert Enum.sort(Enum.map(rows, & &1["id"])) == Enum.sort(@ids)

    for row <- rows do
      assert {:ok, built} = build_request(request(row), config(row))
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert built.max_bytes == 16 * 1024 * 1024
      assert built.output_format == row["result"]["outputFormat"], row["id"]
      assert built.file_extension == row["result"]["fileExtension"], row["id"]
      assert built.voice_compatible == row["result"]["voiceCompatible"], row["id"]
      assert built.sample_rate == row["result"]["sampleRate"], row["id"]
    end
  end

  for id <-
        ~w(custom-voice-model provider-overrides extra-body-fields extra-body-final-wins telephony) do
    @id id
    test "#{id} sends the pinned body through a custom HTTP endpoint and preserves returned bytes",
         %{fixture: fixture} do
      row = Enum.find(observations(), &(&1["id"] == @id))
      audio = Base.decode64!(row["result"]["audioBase64"])
      expect_audio(fixture, "/proxy/audio/speech", row["request"]["body"], audio)
      configured = Map.put(config(row), :base_url, Gaoxy.Test.url(fixture, "/proxy///"))

      assert {:ok, result} = synthesize(request(row), configured)
      assert result == result(row, audio)
      assert_receive {:speech_body, body}, 1_000
      assert body == row["request"]["body"]
    end
  end

  test "a chunked tiny PCM WAV is returned byte for byte at the configured byte limit",
       %{fixture: fixture} do
    audio = tiny_wav()

    expected = %{
      "model" => "gpt-4o-mini-tts",
      "input" => "A small ordinary WAV.",
      "voice" => "coral",
      "response_format" => "wav"
    }

    expect_audio(fixture, "/v1/audio/speech", expected, audio, chunked: true)
    request = %{text: expected["input"], target: :voice_note, timeout_ms: 5_000}
    config = local_config(fixture, response_format: " WAV ", max_bytes: byte_size(audio))

    assert {:ok,
            %{
              audio: ^audio,
              output_format: "wav",
              file_extension: ".wav",
              voice_compatible: false
            }} = synthesize(request, config)

    assert {:ok, %{timeout_ms: 5_000, max_bytes: limit}} = build_request(request, config)
    assert limit == byte_size(audio)
    assert_receive {:speech_body, ^expected}, 1_000
  end

  for {target, format, compatible} <- [
        {:audio_file, "mp3", false},
        {:voice_note, "opus", true},
        {:voice_note, "mp3", true}
      ] do
    @target target
    @format format
    @compatible compatible
    test "#{target} #{format} returns opaque audio and its selected file metadata",
         %{fixture: fixture} do
      # These bytes test transport fidelity only; no MP3/Opus decoding is claimed.
      audio = <<0, 255, 128, 1, 13, 10, 0, 254>>

      expected = %{
        "model" => "gpt-4o-mini-tts",
        "input" => "Ordinary speech.",
        "voice" => "coral",
        "response_format" => @format
      }

      expect_audio(fixture, "/v1/audio/speech", expected, audio)

      assert {:ok, result} =
               synthesize(
                 %{text: expected["input"], target: @target},
                 local_config(fixture, response_format: @format)
               )

      assert result == %{
               audio: audio,
               output_format: @format,
               file_extension: "." <> @format,
               voice_compatible: @compatible
             }

      assert_receive {:speech_body, ^expected}, 1_000
    end
  end

  test "distinct ordinary deadlines reuse the shared Finch instance and preserve speech bytes",
       %{fixture: fixture} do
    base_url = Gaoxy.Test.url(fixture, "/pool")
    port = URI.parse(base_url).port
    path = "/pool/audio/speech"
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:finch, :request, :start],
        &__MODULE__.capture_pool_start/4,
        %{owner: owner, port: port, path: path}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    audio = tiny_wav()

    expected = %{
      "model" => "gpt-4o-mini-tts",
      "input" => "Shared ordinary speech pool.",
      "voice" => "coral",
      "response_format" => "wav"
    }

    Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:pool_speech_body, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("audio/wav")
      |> Plug.Conn.resp(200, audio)
    end)

    for timeout <- [1_001, 2_002, 3_003] do
      assert {:ok,
              %{
                audio: ^audio,
                output_format: "wav",
                file_extension: ".wav",
                voice_compatible: false
              }} =
               synthesize(
                 %{text: expected["input"], target: :audio_file, timeout_ms: timeout},
                 %{api_key: "speech-fixture", base_url: base_url, response_format: "wav"}
               )

      assert_receive {:pool_speech_body, ^expected}, 1_000
    end

    names =
      for _ <- 1..3 do
        assert_receive {:speech_pool_started, name}, 1_000
        name
      end

    assert names == [Req.Finch, Req.Finch, Req.Finch]
  end

  test "host defaults and configured ordinary speed boundaries retain the pinned model and voice" do
    for speed <- [0.25, 4] do
      assert {:ok, built} =
               build_request(
                 %{text: "Boundary speed.", target: :audio_file},
                 %{api_key: "speech-fixture", speed: speed}
               )

      assert built.url == "https://api.openai.com/v1/audio/speech"
      assert built.timeout_ms == 30_000

      assert built.body == %{
               "model" => "gpt-4o-mini-tts",
               "input" => "Boundary speed.",
               "voice" => "coral",
               "response_format" => "mp3",
               "speed" => speed
             }
    end
  end

  defp observations,
    do: @reference |> File.read!() |> Jason.decode!() |> Map.fetch!("observations")

  defp request(row) do
    input = row["input"]

    %{
      text: input["text"],
      target: target(input["target"]),
      timeout_ms: input["timeoutMs"],
      provider_overrides: atom_options(input["providerOverrides"] || %{})
    }
  end

  defp config(row), do: atom_options(row["input"]["providerConfig"])

  defp atom_options(options) do
    for {wire, host} <- [
          {"apiKey", :api_key},
          {"baseUrl", :base_url},
          {"model", :model},
          {"voice", :voice},
          {"speed", :speed},
          {"instructions", :instructions},
          {"responseFormat", :response_format},
          {"extraBody", :extra_body},
          {"extra_body", :extra_body}
        ],
        Map.has_key?(options, wire),
        into: %{},
        do: {host, Map.fetch!(options, wire)}
  end

  @doc false
  def capture_pool_start(_event, _measurements, metadata, %{owner: owner, port: port, path: path}) do
    case metadata do
      %{name: name, request: %{port: ^port, path: ^path}} ->
        send(owner, {:speech_pool_started, name})

      _ ->
        :ok
    end
  end

  defp target("audio-file"), do: :audio_file
  defp target("voice-note"), do: :voice_note
  defp target("telephony"), do: :telephony

  defp result(row, audio) do
    Enum.reduce(
      [
        {"fileExtension", :file_extension},
        {"voiceCompatible", :voice_compatible},
        {"sampleRate", :sample_rate}
      ],
      %{audio: audio, output_format: row["result"]["outputFormat"]},
      fn {wire, host}, result ->
        if Map.has_key?(row["result"], wire),
          do: Map.put(result, host, row["result"][wire]),
          else: result
      end
    )
  end

  # Callers explicitly cross the raw configuration boundary. The pinned phone
  # recipes exercise the distinct telephony callback, as in the source factory.
  defp build_request(request, raw) do
    config = resolve_raw(raw)

    if request.target == :telephony,
      do: OpenAI.build_telephony_request(request, config),
      else: OpenAI.build_request(request, config)
  end

  defp synthesize(request, raw) do
    config = resolve_raw(raw)

    if request.target == :telephony,
      do: OpenAI.synthesize_telephony(request, config),
      else: OpenAI.synthesize(request, config)
  end

  defp resolve_raw(raw) do
    raw
    |> Map.new(fn
      {:api_key, value} -> {"apiKey", value}
      {:base_url, value} -> {"baseUrl", value}
      {:response_format, value} -> {"responseFormat", value}
      {:extra_body, value} -> {"extraBody", value}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> OpenAI.resolve_config()
    |> Map.merge(Map.take(raw, [:max_bytes]))
  end

  defp local_config(fixture, options) do
    Map.merge(
      %{api_key: "speech-fixture", base_url: Gaoxy.Test.url(fixture, "/v1")},
      Map.new(options)
    )
  end

  defp expect_audio(fixture, path, expected, audio, options \\ []) do
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded == expected
      send(owner, {:speech_body, decoded})
      conn = Plug.Conn.put_resp_content_type(conn, "application/octet-stream")

      if Keyword.get(options, :chunked, false) do
        conn = Plug.Conn.send_chunked(conn, 200)
        <<first::binary-size(17), rest::binary>> = audio
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
      else
        Plug.Conn.resp(conn, 200, audio)
      end
    end)
  end

  defp tiny_wav do
    # One mono signed-16 PCM sample at 24 kHz, with a complete RIFF/WAVE header.
    <<"RIFF", 38::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data", 2::little-32,
      0::little-signed-16>>
  end
end
