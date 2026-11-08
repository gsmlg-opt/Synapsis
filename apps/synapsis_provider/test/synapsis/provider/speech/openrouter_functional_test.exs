defmodule Synapsis.Provider.Speech.OpenRouterFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.OpenRouter

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openrouter-speech.json",
               __DIR__
             )
  @models [
    "hexgrad/kokoro-82m",
    "elevenlabs/eleven-turbo-v2",
    "google/gemini-3.1-flash-tts-preview",
    "mistralai/voxtral-mini-tts-2603"
  ]
  @base "https://openrouter.ai/api/v1"
  @key "fixture-openrouter-speech"
  @audio <<82, 73, 70, 70, 0, 1, 2, 255>>

  # Literal conclusions from 488631c speech-provider.ts and the complete shared
  # factory, independently cross-checked by openrouter-speech-functional.test.mjs.
  # The capture supplies original inputs, never the sole expected host output.
  test "the ordered source catalog and hosted synthesis timeout remain explicit" do
    assert OpenRouter.models() == @models
    assert OpenRouter.voices() == [%{id: "af_alloy", name: "af_alloy"}]
    assert OpenRouter.default_timeout_ms() == 120_000

    assert {:ok, built} =
             OpenRouter.build_request(%{text: "Default speech", target: :audio_file}, defaults())

    assert built.timeout_ms == 120_000
    assert built.url == @base <> "/audio/speech"
    assert built.body == body("Default speech", %{})
    assert metadata(built) == output("mp3")
    assert Map.drop(built, [:url, :body, :timeout_ms, :max_bytes]) == output("mp3")
  end

  test "all sixteen source synthesis rows match independent config wire metadata and real bytes" do
    reference = reference()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    cases = synthesis_cases()
    assert Enum.map(reference["observations"], & &1["id"]) == Enum.map(cases, & &1.id)

    for {row, expected} <- Enum.zip(reference["observations"], cases) do
      input = row["input"]
      text = Map.get(expected, :text, "Plain speech fixture.")
      config = Map.merge(defaults(), Map.get(expected, :config, %{}))
      wire_body = body(text, Map.get(expected, :body, %{}))
      url = Map.get(expected, :base, @base) <> "/audio/speech"
      format = Map.get(expected, :format, "mp3")
      result = Map.put(output(format), :audio, @audio)

      assert input["text"] == text
      assert OpenRouter.resolve_config(input["rawConfig"]) == config, row["id"]
      assert source_config(row["resolvedConfig"]) == config, row["id"]
      assert row["request"]["url"] == url
      assert row["request"]["body"] == wire_body
      assert source_result(row["result"]) == result
      assert row["providerMetadata"]["models"] == @models
      assert row["providerMetadata"]["defaultTimeoutMs"] == 120_000
      assert row["listVoices"] == [%{"id" => "af_alloy", "name" => "af_alloy"}]

      request = %{
        text: text,
        target: source_target(input["target"]),
        timeout_ms: 12_345,
        provider_overrides: source_overrides(input["providerOverrides"] || %{})
      }

      assert {:ok, built} = OpenRouter.build_request(request, config)
      assert built.url == url, row["id"]
      assert built.body == wire_body, row["id"]
      assert built.timeout_ms == 12_345
      assert metadata(built) == output(format)
      assert Map.drop(built, [:url, :body, :timeout_ms, :max_bytes]) == output(format)

      fixture = Gaoxy.Test.open()

      try do
        path = URI.parse(url).path
        prefix = URI.parse(Map.get(expected, :base, @base)).path
        local = Map.put(config, :base_url, Gaoxy.Test.url(fixture, prefix))
        owner = self()
        token = make_ref()

        Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
          {:ok, data, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:openrouter_http, token, conn.method, conn.request_path, conn.query_string,
             Jason.decode!(data), Map.new(conn.req_headers)}
          )

          conn =
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, <<82, 73, 70>>)
          {:ok, conn} = Plug.Conn.chunk(conn, <<70, 0, 1, 2, 255>>)
          conn
        end)

        assert {:ok, local_built} = OpenRouter.build_request(request, local)
        assert local_built.url == Gaoxy.Test.url(fixture, path)
        assert local_built.body == wire_body
        assert {:ok, ^result} = OpenRouter.synthesize(request, local)

        assert_receive {:openrouter_http, ^token, "POST", ^path, "", ^wire_body, headers},
                       1000

        # These fixture header assertions record ordinary wire provenance only.
        assert headers["content-type"] == "application/json"
        assert headers["authorization"] == "Bearer fixture-openrouter-speech"
      after
        Gaoxy.Test.close(fixture)
      end

      assert input == row["inputAfter"]
      assert row["synthesisRequest"] == row["synthesisRequestAfter"]
    end
  end

  test "all three Talk config callbacks retain base routing and use Talk modelId" do
    expected = [
      {"talk-defaults", defaults()},
      {"talk-configured",
       %{
         api_key: "fixture-talk-speech",
         base_url: "https://talk.example/router/v2",
         model: "mistralai/voxtral-mini-tts-2603",
         voice: "talk-voice",
         speed: 1.2,
         response_format: "pcm",
         provider: %{"order" => ["ordinary-route"]}
       }},
      {"talk-speaker",
       Map.merge(defaults(), %{
         base_url: @base,
         model: "elevenlabs/eleven-turbo-v2",
         voice: "talk-speaker",
         response_format: "mp3"
       })}
    ]

    rows = reference()["talkConfigObservations"]
    assert Enum.map(rows, & &1["id"]) == Enum.map(expected, &elem(&1, 0))

    for {row, {_id, config}} <- Enum.zip(rows, expected) do
      input = row["input"]

      assert OpenRouter.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"]) ==
               config

      assert source_config(row["result"]) == config
      assert row["inputAfter"] == input
    end

    assert OpenRouter.resolve_talk_config(
             %{"providers" => %{"openrouter" => %{"model" => "saved-model"}}},
             %{"model" => "unused-talk-alias", "speed" => 0}
           ) == %{model: "saved-model", voice: "af_alloy", speed: 0}
  end

  test "all four Talk override callbacks select ID aliases before trimming" do
    expected = [
      {"talk-id-overrides", %{voice: "vf", model: "model-id", speed: 1.25}},
      {"talk-alias-overrides", %{voice: "v", model: "m", speed: 0.9}},
      {"talk-blank-overrides", %{}},
      {"talk-blank-id-overrides", %{speed: 1.1}}
    ]

    rows = reference()["talkOverrideObservations"]
    assert Enum.map(rows, & &1["id"]) == Enum.map(expected, &elem(&1, 0))

    for {row, {_id, overrides}} <- Enum.zip(rows, expected) do
      assert OpenRouter.resolve_talk_overrides(row["input"]["params"]) == overrides
      assert source_config(row["result"]) == overrides
      assert row["inputAfter"] == row["input"]
    end
  end

  test "nested empty config and nullish selection preserve source absence and precedence" do
    assert OpenRouter.resolve_config(%{
             "providers" => %{"openrouter" => %{}},
             "openrouter" => %{"model" => "legacy-model", "voice" => "legacy-voice"}
           }) == %{model: "hexgrad/kokoro-82m", voice: "af_alloy"}

    config =
      OpenRouter.resolve_config(%{
        "providers" => %{
          "openrouter" => %{
            "apiKey" => @key,
            "model" => " ",
            "modelId" => "unused-model",
            "speakerVoice" => " ",
            "speakerVoiceId" => " speaker-id ",
            "voice" => "unused-voice",
            "speed" => 0
          }
        }
      })

    assert config == Map.merge(defaults(), %{voice: "speaker-id", speed: 0})

    assert {:ok, built} =
             OpenRouter.build_request(
               %{
                 text: "Alias precedence",
                 target: :voice_note,
                 provider_overrides: %{
                   model: " ",
                   model_id: "unused-model",
                   voice: " ",
                   voice_id: "unused-voice",
                   speed: 0
                 }
               },
               config
             )

    assert built.body == body("Alias precedence", %{"voice" => "speaker-id", "speed" => 0})

    assert {:ok, custom} =
             OpenRouter.build_request(
               %{text: "Custom catalog selection", target: :audio_file},
               Map.merge(defaults(), %{model: "ordinary/custom-tts", voice: "ordinary-voice"})
             )

    assert custom.body ==
             body("Custom catalog selection", %{
               "model" => "ordinary/custom-tts",
               "voice" => "ordinary-voice"
             })
  end

  test "ordinary successful HTTP uses the full default and explicit deadline options" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    Code.ensure_loaded!(Req)

    for arity <- [1, 2], do: :erlang.trace_pattern({Req, :request, arity}, true, [:local])

    try do
      Gaoxy.Test.stub(fixture, "POST", "/deadline/audio/speech", fn conn ->
        Plug.Conn.resp(conn, 200, @audio)
      end)

      for {request_options, timeout} <- [{%{}, 120_000}, {%{timeout_ms: 75_000}, 75_000}] do
        caller = self()

        request =
          Map.merge(%{text: "Full ordinary deadline", target: :audio_file}, request_options)

        config = Map.put(defaults(), :base_url, Gaoxy.Test.url(fixture, "/deadline"))

        task =
          Task.async(fn ->
            receive do
              :synthesize -> OpenRouter.synthesize(request, config)
            end
          end)

        :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, caller}])
        send(task.pid, :synthesize)
        assert {:ok, result} = Task.await(task, 5000)
        assert result == Map.put(output("mp3"), :audio, @audio)
        barrier = :erlang.trace_delivered(:all)
        assert_receive {:trace_delivered, :all, ^barrier}, 1000
        calls = drain_requests([])
        assert calls != []

        for {http_owner, request} <- calls do
          refute http_owner == caller
          assert request.options.receive_timeout == timeout
          assert request.options.request_timeout == timeout
          assert request.options.finch[:pool_timeout] == timeout
        end
      end
    after
      for arity <- [1, 2], do: :erlang.trace_pattern({Req, :request, arity}, false, [:local])
    end
  end

  defp synthesis_cases do
    [
      %{id: "default-file"},
      %{
        id: "configured",
        config: %{
          base_url: @base,
          model: "google/gemini-3.1-flash-tts-preview",
          voice: "Kore",
          speed: 1.1,
          response_format: "mp3",
          provider: %{"options" => %{"openai" => %{"instructions" => "Speak warmly."}}}
        },
        body: %{
          "model" => "google/gemini-3.1-flash-tts-preview",
          "voice" => "Kore",
          "speed" => 1.1,
          "provider" => %{"options" => %{"openai" => %{"instructions" => "Speak warmly."}}}
        }
      },
      %{
        id: "custom-prefix",
        base: "https://speech.example/router/v7",
        config: %{
          base_url: "https://speech.example/router/v7",
          model: "mistralai/voxtral-mini-tts-2603",
          voice: "ordinary-voice",
          speed: 0.9,
          provider: %{"order" => ["ordinary-route"]}
        },
        body: %{
          "model" => "mistralai/voxtral-mini-tts-2603",
          "voice" => "ordinary-voice",
          "speed" => 0.9,
          "provider" => %{"order" => ["ordinary-route"]}
        }
      },
      %{
        id: "overrides",
        config: %{model: "elevenlabs/eleven-turbo-v2", voice: "configured-voice", speed: 0.8},
        body: %{
          "model" => "google/gemini-3.1-flash-tts-preview",
          "voice" => "Kore",
          "speed" => 1.2
        }
      },
      %{
        id: "id-alias-overrides",
        body: %{
          "model" => "mistralai/voxtral-mini-tts-2603",
          "voice" => "ordinary-id",
          "speed" => 1.1
        }
      },
      %{
        id: "override-key-precedence",
        body: %{"model" => "google/gemini-3.1-flash-tts-preview", "voice" => "Kore"}
      },
      %{
        id: "blank-overrides",
        config: %{model: "elevenlabs/eleven-turbo-v2", voice: "configured-voice", speed: 0.9},
        body: %{
          "model" => "elevenlabs/eleven-turbo-v2",
          "voice" => "configured-voice",
          "speed" => 0.9
        }
      },
      %{id: "speaker-precedence", config: %{voice: "speaker-v"}, body: %{"voice" => "speaker-v"}},
      %{id: "speaker-id", config: %{voice: "speaker-id"}, body: %{"voice" => "speaker-id"}},
      %{id: "unicode-trim", config: %{speed: 1.25}, body: %{"speed" => 1.25}},
      %{
        id: "pcm-file",
        config: %{response_format: "pcm", provider: %{"order" => []}},
        body: %{"response_format" => "pcm", "provider" => %{"order" => []}},
        format: "pcm"
      },
      %{id: "default-note"},
      %{
        id: "pcm-note",
        config: %{response_format: "pcm"},
        body: %{"response_format" => "pcm"},
        format: "pcm"
      },
      %{id: "authored-text", text: "  Ordinary speech.\n你好 🌍 — café.\t "},
      %{
        id: "legacy-config",
        config: %{model: "elevenlabs/eleven-turbo-v2", voice: "legacy-voice"},
        body: %{"model" => "elevenlabs/eleven-turbo-v2", "voice" => "legacy-voice"}
      },
      %{
        id: "nested-precedence",
        config: %{model: "google/gemini-3.1-flash-tts-preview", voice: "nested-voice"},
        body: %{"model" => "google/gemini-3.1-flash-tts-preview", "voice" => "nested-voice"}
      }
    ]
  end

  defp reference, do: @reference |> File.read!() |> Jason.decode!()
  defp defaults, do: %{api_key: @key, model: "hexgrad/kokoro-82m", voice: "af_alloy"}

  defp body(text, fields) do
    Map.merge(
      %{
        "model" => "hexgrad/kokoro-82m",
        "input" => text,
        "voice" => "af_alloy",
        "response_format" => "mp3"
      },
      fields
    )
  end

  defp output(format),
    do: %{output_format: format, file_extension: "." <> format, voice_compatible: format == "mp3"}

  defp metadata(built),
    do: Map.take(built, [:output_format, :file_extension, :voice_compatible])

  defp source_config(config) do
    for {source, target} <- [
          {"apiKey", :api_key},
          {"baseUrl", :base_url},
          {"model", :model},
          {"voice", :voice},
          {"speed", :speed},
          {"responseFormat", :response_format},
          {"provider", :provider}
        ],
        Map.has_key?(config, source),
        into: %{},
        do: {target, config[source]}
  end

  defp source_overrides(config) do
    for {source, target} <- [
          {"model", :model},
          {"modelId", :model_id},
          {"voice", :voice},
          {"voiceId", :voice_id},
          {"speed", :speed}
        ],
        Map.has_key?(config, source),
        into: %{},
        do: {target, config[source]}
  end

  defp source_result(result) do
    %{
      audio: Base.decode64!(result["audioBase64"]),
      output_format: result["outputFormat"],
      file_extension: result["fileExtension"],
      voice_compatible: result["voiceCompatible"]
    }
  end

  defp source_target("audio-file"), do: :audio_file
  defp source_target("voice-note"), do: :voice_note

  defp drain_requests(calls) do
    receive do
      {:trace, pid, :call, {Req, :request, [%Req.Request{} = request | _]}} ->
        drain_requests([{pid, request} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
