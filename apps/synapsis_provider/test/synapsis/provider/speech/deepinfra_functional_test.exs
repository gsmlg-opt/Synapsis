defmodule Synapsis.Provider.Speech.DeepInfraFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.DeepInfra

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/deepinfra-speech.json",
               __DIR__
             )
  @models [
    "hexgrad/Kokoro-82M",
    "Qwen/Qwen3-TTS",
    "ResembleAI/chatterbox-turbo",
    "sesame/csm-1b"
  ]
  @base "https://api.deepinfra.com/v1/openai"
  @key "fixture-deepinfra-speech"
  @audio <<82, 73, 70, 70, 0, 1, 2, 255>>

  # Literal conclusions from the pinned DeepInfra factory/media-models and shared
  # speech implementation. The fixture supplies original inputs and an independent
  # source comparison; neither host execution nor capture generates these expectations.
  test "fallback catalog and hosted default stay explicit while custom model strings work" do
    assert DeepInfra.models() == @models
    assert DeepInfra.voices() == [%{id: "af_bella", name: "af_bella"}]
    assert DeepInfra.default_timeout_ms() == 120_000

    assert {:ok, built} =
             DeepInfra.build_request(%{text: "Default speech", target: :audio_file}, defaults())

    assert built.url == @base <> "/audio/speech"
    assert built.timeout_ms == 120_000
    assert built.body == body("Default speech", %{})
    assert Map.drop(built, [:url, :body, :timeout_ms, :max_bytes]) == output("mp3")

    assert {:ok, custom} =
             DeepInfra.build_request(
               %{text: "Explicit custom model", target: :audio_file},
               Map.merge(defaults(), %{model: "ordinary/custom-tts", voice: "ordinary-voice"})
             )

    assert custom.body ==
             body("Explicit custom model", %{
               "model" => "ordinary/custom-tts",
               "voice" => "ordinary-voice"
             })

    assert {:ok, custom_prefix} =
             DeepInfra.build_request(
               %{text: "Explicit prefix", target: :audio_file},
               Map.put(defaults(), :base_url, " https://api.deepinfra.com/v1/// ")
             )

    assert custom_prefix.url == "https://api.deepinfra.com/v1/audio/speech"
    assert custom_prefix.body == body("Explicit prefix", %{})
  end

  test "all 34 fallback-compatible source synthesis rows match literal config wire metadata and HTTP bytes" do
    reference = reference()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    cases = synthesis_cases()

    # Optional nondefault factory ttsModels belongs to the source plugin catalog
    # feed. This host uses fallback metadata and explicit custom model strings;
    # it does not invent a factory/discovery API. Empty factory options are fallback.
    rows = Enum.reject(reference["observations"], &(&1["id"] == "factory-custom-catalog"))
    assert length(rows) == 34
    assert Enum.map(rows, & &1["id"]) == Enum.map(cases, & &1.id)

    for {row, expected} <- Enum.zip(rows, cases) do
      input = row["input"]
      text = Map.get(expected, :text, "Plain speech fixture.")
      config = Map.merge(defaults(), Map.get(expected, :config, %{}))
      wire_body = body(text, Map.get(expected, :body, %{}))
      url = Map.get(expected, :base, @base) <> "/audio/speech"
      format = Map.get(expected, :format, "mp3")
      result = Map.put(output(format), :audio, @audio)

      assert input["text"] == text
      assert DeepInfra.resolve_config(input["rawConfig"]) == config, row["id"]
      assert source_config(row["resolvedConfig"]) == config, row["id"]
      assert row["request"]["url"] == url
      assert row["request"]["body"] == wire_body
      assert source_result(row["result"]) == result
      assert row["providerMetadata"]["models"] == @models
      assert row["providerMetadata"]["defaultTimeoutMs"] == 120_000
      assert row["listVoices"] == [%{"id" => "af_bella", "name" => "af_bella"}]

      request = %{
        text: text,
        target: source_target(input["target"]),
        timeout_ms: 12_345,
        provider_overrides: source_overrides(input["providerOverrides"] || %{})
      }

      assert {:ok, built} = DeepInfra.build_request(request, config)
      assert built.url == url, row["id"]
      assert built.body == wire_body, row["id"]
      assert built.timeout_ms == 12_345
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
            {:deepinfra_http, token, conn.method, conn.request_path, conn.query_string,
             Jason.decode!(data)}
          )

          conn =
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, <<82, 73, 70>>)
          {:ok, conn} = Plug.Conn.chunk(conn, <<70, 0, 1, 2, 255>>)
          conn
        end)

        assert {:ok, local_built} = DeepInfra.build_request(request, local)
        assert local_built.url == Gaoxy.Test.url(fixture, path)
        assert local_built.body == wire_body
        assert {:ok, ^result} = DeepInfra.synthesize(request, local)
        assert_receive {:deepinfra_http, ^token, "POST", ^path, "", ^wire_body}, 1000
      after
        Gaoxy.Test.close(fixture)
      end

      assert input == row["inputAfter"]
      assert row["synthesisRequest"] == row["synthesisRequestAfter"]
    end
  end

  test "five Talk configuration callbacks retain base extraBody and source modelId precedence" do
    expected = [
      {"talk-defaults", defaults()},
      {"talk-configured",
       %{
         api_key: "fixture-talk-speech",
         base_url: "https://talk.example/deepinfra/v2",
         model: "Qwen/Qwen3-TTS",
         voice: "talk-voice",
         speed: 1.2,
         response_format: "flac",
         extra_body: %{"base" => true, "options" => %{"seed" => 7}}
       }},
      {"talk-speaker",
       Map.merge(defaults(), %{
         base_url: @base,
         model: "ResembleAI/chatterbox-turbo",
         voice: "talk-speaker",
         response_format: "opus",
         extra_body: %{"retained" => true}
       })},
      {"talk-model-alias-unselected",
       Map.merge(defaults(), %{model: "sesame/csm-1b", voice: "voice-id", speed: 0})},
      {"talk-empty-nested-precedence", %{model: "hexgrad/Kokoro-82M", voice: "af_bella"}}
    ]

    rows = reference()["talkConfigObservations"]
    assert Enum.map(rows, & &1["id"]) == Enum.map(expected, &elem(&1, 0))

    for {row, {_id, config}} <- Enum.zip(rows, expected) do
      input = row["input"]

      assert DeepInfra.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"]) ==
               config

      assert source_config(row["result"]) == config
      assert row["inputAfter"] == input
    end
  end

  test "Talk overrides select ID aliases before trimming and leave namespace normalization to synthesis" do
    expected = [
      {"talk-id-overrides", %{voice: "vf", model: "deepinfra/Qwen/Qwen3-TTS", speed: 1.25}},
      {"talk-alias-overrides", %{voice: "v", model: "deepinfra/sesame/csm-1b", speed: 0.9}},
      {"talk-blank-overrides", %{}},
      {"talk-blank-id-overrides", %{speed: 1.1}}
    ]

    rows = reference()["talkOverrideObservations"]
    assert Enum.map(rows, & &1["id"]) == Enum.map(expected, &elem(&1, 0))

    for {row, {_id, overrides}} <- Enum.zip(rows, expected) do
      assert DeepInfra.resolve_talk_overrides(row["input"]["params"]) == overrides
      assert source_config(row["result"]) == overrides
      assert row["inputAfter"] == row["input"]
    end
  end

  test "nested empty config and nullish model choice retain default absence and zero speed" do
    assert DeepInfra.resolve_config(%{
             "providers" => %{"deepinfra" => %{}},
             "deepinfra" => %{"model" => "legacy-model", "voice" => "legacy-voice"}
           }) == %{model: "hexgrad/Kokoro-82M", voice: "af_bella"}

    config =
      DeepInfra.resolve_config(%{
        "providers" => %{
          "deepinfra" => %{
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
             DeepInfra.build_request(
               %{
                 text: "Ordinary alias precedence",
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

    assert built.body ==
             body("Ordinary alias precedence", %{"voice" => "speaker-id", "speed" => 0})
  end

  test "ordinary successful HTTP keeps full default and explicit timeout options" do
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
              :synthesize -> DeepInfra.synthesize(request, config)
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
    formats =
      Enum.flat_map(~w(mp3 opus flac wav pcm), fn format ->
        for target <- ~w(file note) do
          %{
            id: "format-#{format}-#{target}",
            config: %{response_format: format},
            body: %{"response_format" => format},
            format: format
          }
        end
      end)

    [
      %{id: "default-file"},
      %{id: "default-note"}
    ] ++
      formats ++
      [
        %{
          id: "configured",
          config: %{
            base_url: @base,
            model: "Qwen/Qwen3-TTS",
            voice: "configured-voice",
            speed: 1.1,
            response_format: "opus",
            extra_body: %{"temperature" => 0.6}
          },
          body: %{
            "model" => "Qwen/Qwen3-TTS",
            "voice" => "configured-voice",
            "speed" => 1.1,
            "response_format" => "opus",
            "extra_body" => %{"temperature" => 0.6}
          },
          format: "opus"
        },
        %{
          id: "custom-prefix",
          base: "https://speech.example/deepinfra/v7",
          config: %{
            base_url: "https://speech.example/deepinfra/v7",
            model: "ResembleAI/chatterbox-turbo",
            voice: "ordinary-voice",
            speed: 0.9
          },
          body: %{
            "model" => "ResembleAI/chatterbox-turbo",
            "voice" => "ordinary-voice",
            "speed" => 0.9
          }
        },
        %{
          id: "configured-namespace",
          config: %{model: "Qwen/Qwen3-TTS"},
          body: %{"model" => "Qwen/Qwen3-TTS"}
        },
        %{
          id: "overrides",
          config: %{model: "Qwen/Qwen3-TTS", voice: "configured-voice", speed: 0.8},
          body: %{
            "model" => "ResembleAI/chatterbox-turbo",
            "voice" => "override-voice",
            "speed" => 1.2
          }
        },
        %{
          id: "id-alias-overrides",
          body: %{"model" => "sesame/csm-1b", "voice" => "ordinary-id", "speed" => 1.1}
        },
        %{
          id: "override-key-precedence",
          body: %{"model" => "Qwen/Qwen3-TTS", "voice" => "primary-voice"}
        },
        %{
          id: "blank-selected-overrides",
          config: %{model: "Qwen/Qwen3-TTS", voice: "configured-voice", speed: 0.9},
          body: %{"model" => "Qwen/Qwen3-TTS", "voice" => "configured-voice", "speed" => 0.9}
        },
        %{
          id: "config-key-precedence",
          config: %{model: "Qwen/Qwen3-TTS", voice: "primary-voice"},
          body: %{"model" => "Qwen/Qwen3-TTS", "voice" => "primary-voice"}
        },
        %{id: "blank-selected-config-model"},
        %{
          id: "speaker-precedence",
          config: %{voice: "speaker-v"},
          body: %{"voice" => "speaker-v"}
        },
        %{id: "speaker-id", config: %{voice: "speaker-id"}, body: %{"voice" => "speaker-id"}},
        %{
          id: "blank-speaker-fallback",
          config: %{voice: "ordinary-voice"},
          body: %{"voice" => "ordinary-voice"}
        },
        %{id: "unicode-trim", config: %{speed: 1.25}, body: %{"speed" => 1.25}},
        %{id: "zero-speed", config: %{speed: 0}, body: %{"speed" => 0}},
        %{
          id: "nested-extra-body",
          config: %{extra_body: nested_extra_body()},
          body: %{"extra_body" => nested_extra_body()}
        },
        %{id: "authored-text", text: "  Ordinary speech.\n你好 🌍 — café.\t "},
        %{
          id: "legacy-config",
          config: %{
            model: "sesame/csm-1b",
            voice: "legacy-voice",
            extra_body: %{"legacy" => true}
          },
          body: %{
            "model" => "sesame/csm-1b",
            "voice" => "legacy-voice",
            "extra_body" => %{"legacy" => true}
          }
        },
        %{
          id: "nested-precedence",
          config: %{
            model: "Qwen/Qwen3-TTS",
            voice: "nested-voice",
            extra_body: %{"nested" => true}
          },
          body: %{
            "model" => "Qwen/Qwen3-TTS",
            "voice" => "nested-voice",
            "extra_body" => %{"nested" => true}
          }
        },
        %{
          id: "case-sensitive-model-prefix",
          config: %{model: "DeepInfra/Qwen/Qwen3-TTS"},
          body: %{"model" => "DeepInfra/Qwen/Qwen3-TTS"}
        },
        %{id: "single-model-prefix-strip", body: %{"model" => "deepinfra/Qwen/Qwen3-TTS"}},
        %{id: "factory-empty-catalog"},
        %{
          id: "configured-repeated-namespace",
          config: %{model: "deepinfra/deepinfra/Qwen/Qwen3-TTS"},
          body: %{"model" => "Qwen/Qwen3-TTS"}
        }
      ]
  end

  defp nested_extra_body do
    %{
      "model" => "nested-model",
      "voice" => "nested-voice",
      "input" => "nested-input",
      "response_format" => "nested-format",
      "speed" => 1.7,
      "extra_body" => %{"nested" => true},
      "options" => %{"seeds" => [7, 11], "style" => %{"language" => "中文", "enabled" => true}},
      "tags" => ["one", %{"two" => 2}]
    }
  end

  defp reference, do: @reference |> File.read!() |> Jason.decode!()
  defp defaults, do: %{api_key: @key, model: "hexgrad/Kokoro-82M", voice: "af_bella"}

  defp body(text, fields) do
    Map.merge(
      %{
        "model" => "hexgrad/Kokoro-82M",
        "input" => text,
        "voice" => "af_bella",
        "response_format" => "mp3"
      },
      fields
    )
  end

  defp output(format),
    do: %{
      output_format: format,
      file_extension: "." <> format,
      voice_compatible: format in ~w(mp3 opus)
    }

  defp source_config(config) do
    for {source, target} <- [
          {"apiKey", :api_key},
          {"baseUrl", :base_url},
          {"model", :model},
          {"voice", :voice},
          {"speed", :speed},
          {"responseFormat", :response_format},
          {"extraBody", :extra_body}
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
