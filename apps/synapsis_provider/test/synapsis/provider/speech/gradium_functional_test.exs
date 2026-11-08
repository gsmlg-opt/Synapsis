defmodule Synapsis.Provider.Speech.GradiumFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.Gradium

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/gradium-speech.json",
               __DIR__
             )
  @voices [
    %{id: "YTpq7expH9539ERJ", name: "Emma"},
    %{id: "LFZvm12tW_z0xfGo", name: "Kent"},
    %{id: "Eu9iL_CYe8N-Gkx_", name: "Tiffany"},
    %{id: "2H4HY2CBNyJHBCrP", name: "Christina"},
    %{id: "jtEKaLYNn6iif5PR", name: "Sydney"},
    %{id: "KWJiFWu2O9nMPYcR", name: "John"},
    %{id: "3jUdJyOi9pgbxBTK", name: "Arthur"}
  ]

  # Independent ordinary contract from the complete pinned Gradium provider and
  # shared.ts. Source fixtures qualify opaque byte transport, not audio decoding.
  test "the static voice catalog retains all seven original IDs names and order" do
    assert Gradium.voices() == @voices
  end

  test "defaults retain authored text and the exact Gradium JSON request" do
    text = "  Ordinary speech.\n你好 🌍 — café.\t "

    assert {:ok, built} =
             Gradium.build_request(%{text: text, target: :audio_file}, %{
               api_key: "ordinary-gradium-fixture"
             })

    assert built.url == "https://api.gradium.ai/api/post/speech/tts"
    assert built.body == body(text, "YTpq7expH9539ERJ", "wav")
    assert built.timeout_ms == 30_000

    assert metadata(built) == %{
             output_format: "wav",
             file_extension: ".wav",
             voice_compatible: false
           }

    assert is_binary(built.body["json_config"])
    assert Jason.decode!(built.body["json_config"]) == %{"padding_bonus" => 0}
  end

  test "configured Unicode voice trimming and trusted custom prefix retain source body shape" do
    assert {:ok, built} =
             Gradium.build_request(%{text: "Configured speech", target: :audio_file}, %{
               api_key: "ordinary-gradium-fixture",
               base_url: " https://speech.example/custom/v7/// ",
               voice_id: "\u00A0\uFEFF LFZvm12tW_z0xfGo \uFEFF\u00A0",
               max_bytes: 4096
             })

    assert built.url == "https://speech.example/custom/v7/api/post/speech/tts"
    assert built.body == body("Configured speech", "LFZvm12tW_z0xfGo", "wav")

    assert metadata(built) == %{
             output_format: "wav",
             file_extension: ".wav",
             voice_compatible: false
           }
  end

  test "explicit voice override and deadline leave both caller inputs unchanged" do
    config = %{api_key: "ordinary-gradium-fixture", voice_id: "LFZvm12tW_z0xfGo"}

    request = %{
      text: "Invocation speech",
      target: :audio_file,
      timeout_ms: 4321,
      provider_overrides: %{voice_id: " Eu9iL_CYe8N-Gkx_ "}
    }

    assert {:ok, built} = Gradium.build_request(request, config)
    assert built.body == body("Invocation speech", "Eu9iL_CYe8N-Gkx_", "wav")
    assert built.timeout_ms == 4321
    assert config == %{api_key: "ordinary-gradium-fixture", voice_id: "LFZvm12tW_z0xfGo"}
    assert request.provider_overrides == %{voice_id: " Eu9iL_CYe8N-Gkx_ "}
  end

  for {target, format, expected} <- [
        {:audio_file, "wav",
         %{output_format: "wav", file_extension: ".wav", voice_compatible: false}},
        {:voice_note, "opus",
         %{output_format: "opus", file_extension: ".opus", voice_compatible: true}},
        {:telephony, "ulaw_8000", %{output_format: "ulaw_8000", sample_rate: 8000}}
      ] do
    @target target
    @format format
    @expected expected
    test "#{target} sends exact JSON and preserves ordered opaque HTTP audio" do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()
      audio = <<0, 255, 128, 1, 13, 10, 0, 254, 42>>
      expected = body("Opaque speech", "LFZvm12tW_z0xfGo", @format)

      Gaoxy.Test.expect_once(fixture, "POST", "/custom/v7/api/post/speech/tts", fn conn ->
        {:ok, data, conn} = Plug.Conn.read_body(conn)

        send(
          owner,
          {:gradium_http, conn.method, conn.request_path, conn.query_string, Jason.decode!(data),
           Map.new(conn.req_headers)}
        )

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_chunked(200)

        <<first::binary-size(4), rest::binary>> = audio
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
      end)

      request = %{text: "Opaque speech", target: @target, timeout_ms: 5000}

      config = %{
        api_key: "ordinary-gradium-fixture",
        base_url: Gaoxy.Test.url(fixture, "/custom/v7///"),
        voice_id: "LFZvm12tW_z0xfGo",
        max_bytes: 4096
      }

      assert {:ok, built} = Gradium.build_request(request, config)
      assert built.url == Gaoxy.Test.url(fixture, "/custom/v7/api/post/speech/tts")
      assert built.body == expected
      assert built.timeout_ms == 5000
      assert metadata(built) == @expected
      assert {:ok, result} = Gradium.synthesize(request, config)
      assert result == Map.put(@expected, :audio, audio)

      assert_receive {:gradium_http, "POST", "/custom/v7/api/post/speech/tts", "", ^expected,
                      headers},
                     1000

      assert headers["content-type"] == "application/json"
      assert headers["x-api-key"] == "ordinary-gradium-fixture"
    end
  end

  test "ordinary distinct deadlines use a linked task and the shared Finch pool" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()
    url = Gaoxy.Test.url(fixture, "/pool")
    handler = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(handler, [:finch, :request, :start], &__MODULE__.pool_start/4, %{
               owner: owner,
               port: URI.parse(url).port
             })

    on_exit(fn -> :telemetry.detach(handler) end)
    audio = <<0, 255, 128, 1>>
    expected = body("Shared pool", "YTpq7expH9539ERJ", "wav")

    Gaoxy.Test.stub(fixture, "POST", "/pool/api/post/speech/tts", fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      send(owner, {:gradium_pool_body, Jason.decode!(data)})
      Plug.Conn.resp(conn, 200, audio)
    end)

    for timeout <- [1001, 2002, 3003] do
      request = %{text: "Shared pool", target: :audio_file, timeout_ms: timeout}
      config = %{api_key: "ordinary-gradium-fixture", base_url: url}
      assert {:ok, built} = Gradium.build_request(request, config)
      assert built.timeout_ms == timeout
      assert {:ok, %{audio: ^audio}} = Gradium.synthesize(request, config)
      assert_receive {:gradium_pool_body, ^expected}, 1000
      assert_receive {:gradium_pool, Req.Finch, transport, links}, 1000
      refute transport == owner
      assert owner in links
    end
  end

  test "all twelve pinned ordinary rows match full requests metadata catalog and real HTTP bytes" do
    reference = @reference |> File.read!() |> Jason.decode!()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"

    assert Enum.map(reference["observations"], & &1["id"]) ==
             [
               "default-file",
               "configured",
               "voice-override",
               "blank-override",
               "unicode-trim",
               "default-note",
               "configured-note",
               "override-note",
               "default-telephony",
               "configured-telephony",
               "override-telephony",
               "authored-text"
             ]

    for row <- reference["observations"] do
      input = row["input"]
      raw = get_in(input, ["rawConfig", "providers", "gradium"])
      config = source_options(raw)

      request = %{
        text: input["text"],
        target: source_target(input["target"]),
        timeout_ms: input["timeoutMs"],
        provider_overrides: source_options(input["providerOverrides"] || %{})
      }

      expected = source_result(row["result"])
      catalog = Enum.map(@voices, &%{"id" => &1.id, "name" => &1.name})
      assert row["listVoices"] == catalog
      assert Gradium.voices() == @voices
      assert {:ok, built} = Gradium.build_request(request, config)
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert metadata(built) == Map.delete(expected, :audio), row["id"]

      fixture = Gaoxy.Test.open()

      try do
        uri = URI.parse(built.url)
        source_base = Map.get(config, :base_url, "https://api.gradium.ai")

        local =
          Map.put(config, :base_url, Gaoxy.Test.url(fixture, URI.parse(source_base).path || "/"))

        owner = self()
        token = make_ref()

        Gaoxy.Test.expect_once(fixture, "POST", uri.path, fn conn ->
          {:ok, data, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:gradium_source_http, token, conn.method, conn.request_path,
             URI.decode_query(conn.query_string), Jason.decode!(data), Map.new(conn.req_headers)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.resp(
            row["response"]["status"],
            Base.decode64!(row["response"]["audioBase64"])
          )
        end)

        assert {:ok, local_built} = Gradium.build_request(request, local)
        assert local_built.url == Gaoxy.Test.url(fixture, uri.path)
        assert local_built.body == built.body
        assert {:ok, result} = Gradium.synthesize(request, local)
        assert result == expected, row["id"]
        assert_receive {:gradium_source_http, ^token, method, path, query, body, headers}, 1000
        assert method == row["request"]["method"]
        assert path == row["request"]["path"]
        assert query == row["request"]["query"]
        assert body == row["request"]["body"]
        assert headers["content-type"] == row["request"]["headers"]["Content-Type"]
        assert headers["x-api-key"] == row["request"]["headers"]["x-api-key"]
      after
        Gaoxy.Test.close(fixture)
      end

      assert input == row["inputAfter"]
      assert row["synthesisRequest"] == row["synthesisRequestAfter"]
      assert config == source_options(raw)
    end
  end

  defp metadata(built),
    do: Map.take(built, [:output_format, :file_extension, :voice_compatible, :sample_rate])

  defp source_options(options) do
    for {source, target} <- [{"apiKey", :api_key}, {"baseUrl", :base_url}, {"voiceId", :voice_id}],
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
      %{name: name, request: %{port: ^port, path: "/pool/api/post/speech/tts"}} ->
        {:links, links} = Process.info(self(), :links)
        send(owner, {:gradium_pool, name, self(), links})

      _ ->
        :ok
    end
  end

  defp body(text, voice, format),
    do: %{
      "text" => text,
      "voice_id" => voice,
      "only_audio" => true,
      "output_format" => format,
      "json_config" => "{\"padding_bonus\":0}"
    }
end
