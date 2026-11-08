defmodule Synapsis.Provider.Speech.VydraFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.Vydra

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/vydra-speech.json",
               __DIR__
             )
  @external_resource @reference
  @base "https://www.vydra.ai/api/v1"
  @model "elevenlabs/tts"
  @voice "21m00Tcm4TlvDq8ikWAM"
  @audio <<82, 73, 70, 70, 0, 1, 2, 255>>
  @text "Ordinary Vydra speech."

  # Expectations are authored from pinned speech-provider.ts/defaults.ts/shared.ts
  # and media-core MIME rules, then compared with the independently captured rows.
  # The capture supplies inputs/provenance, never expected host output.
  test "one model and Rachel voice have explicit source-shaped defaults" do
    assert Vydra.models() == ["elevenlabs/tts"]
    assert Vydra.voices() == [%{id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel"}]
    assert Vydra.resolve_config(%{}) == Map.delete(defaults(), :api_key)
    assert Vydra.resolve_config(raw(%{})) == defaults()

    assert Vydra.resolve_config(
             raw(%{
               "baseUrl" => " https://speech.example.test/custom/v7/// ",
               "model" => " custom/model ",
               "voiceId" => " custom-voice "
             })
           ) ==
             Map.merge(defaults(), %{
               base_url: "https://speech.example.test/custom/v7",
               model: "custom/model",
               voice_id: "custom-voice"
             })

    assert Vydra.resolve_config(
             raw(%{
               "baseUrl" => "\u00A0\uFEFFhttps://vydra.ai/\uFEFF\u00A0",
               "model" => "\u00A0\uFEFF elevenlabs/tts \uFEFF\u00A0",
               "voiceId" => "\u00A0\uFEFF Rachel-custom \uFEFF\u00A0"
             })
           ) == Map.put(defaults(), :voice_id, "Rachel-custom")
  end

  test "declared base strings retain custom prefix port query and fragment semantics" do
    # Pure wire-intent checks: query/fragment concatenation is deliberately literal.
    # These are not a claim about actual HTTP transport of fragment-containing URLs.
    for {base, expected_base, expected_url} <- [
          {"https://vydra.ai/", "https://www.vydra.ai/api/v1",
           "https://www.vydra.ai/api/v1/models/elevenlabs/tts"},
          {" https://voice.example.test/custom/v7/// ", "https://voice.example.test/custom/v7",
           "https://voice.example.test/custom/v7/models/elevenlabs/tts"},
          {"https://voice.example.test", "https://voice.example.test/api/v1",
           "https://voice.example.test/api/v1/models/elevenlabs/tts"},
          {"https://vydra.ai:8443/voice///", "https://www.vydra.ai:8443/voice",
           "https://www.vydra.ai:8443/voice/models/elevenlabs/tts"},
          {"https://vydra.ai/?mode=voice#section",
           "https://www.vydra.ai/api/v1?mode=voice#section",
           "https://www.vydra.ai/api/v1?mode=voice#section/models/elevenlabs/tts"}
        ] do
      config = Vydra.resolve_config(raw(%{"baseUrl" => base}))
      assert config.base_url == expected_base
      assert {:ok, built} = Vydra.build_request(request(), config)
      assert built.url == expected_url
      assert built.body == %{"text" => @text, "voice_id" => @voice}
      assert built.timeout_ms == 12_345
      assert built.max_bytes == 16_777_216
      refute Map.has_key?(built, :output_format)
      refute Map.has_key?(built, :file_extension)
      refute Map.has_key?(built, :media_format)
    end
  end

  test "all 33 source synthesis recipes match independent literal semantics at the host boundary" do
    reference = reference()
    cases = synthesis_cases()
    rows = reference["observations"]
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(rows) == 33
    assert Enum.map(rows, & &1["id"]) == Enum.map(cases, & &1.id)

    assert reference["providerMetadata"] == %{
             "id" => "vydra",
             "label" => "Vydra",
             "models" => ["elevenlabs/tts"],
             "voices" => ["21m00Tcm4TlvDq8ikWAM"],
             "defaultTimeoutMs" => nil
           }

    for {row, expected} <- Enum.zip(rows, cases) do
      input = row["input"]
      text = Map.get(expected, :text, @text)
      timeout = Map.get(expected, :timeout, 12_345)
      config = Map.merge(defaults(), Map.get(expected, :config, %{}))
      model = Map.get(expected, :model, config.model)
      voice = Map.get(expected, :voice, config.voice_id)
      body = %{"text" => text, "voice_id" => voice}
      url = config.base_url <> "/models/" <> model
      result = Map.get(expected, :result, mp3()) |> Map.put(:audio, @audio)

      assert input["text"] == text, expected.id
      assert input["timeoutMs"] == timeout, expected.id
      assert source_config(row["resolvedConfig"]) == config, expected.id
      assert row["request"] == %{"url" => url, "body" => body, "timeoutMs" => timeout}
      assert row["response"]["contentType"] == Map.get(expected, :mime, "audio/mpeg")
      assert source_result(row["result"]) == Map.delete(result, :media_format)
      assert row["inputAfter"] == input
      assert row["synthesisRequestAfter"] == row["synthesisRequest"]

      # Source env fallback is SOURCE-ONLY. For these three rows, the literal
      # source values become explicit saved fields; the host never reads env.
      host_raw =
        case Map.get(expected, :explicit_source_env) do
          nil -> input["rawConfig"]
          fields -> raw(fields)
        end

      assert Vydra.resolve_config(host_raw) == config, expected.id

      req = %{
        text: text,
        target: target(input["target"]),
        timeout_ms: timeout,
        provider_overrides: source_overrides(input["providerOverrides"])
      }

      assert {:ok, built} = Vydra.build_request(req, config)
      assert built.url == url, expected.id
      assert built.body == body, expected.id
      assert built.timeout_ms == timeout
      refute Map.has_key?(built, :output_format)
      refute Map.has_key?(built, :file_extension)
      refute Map.has_key?(built, :media_format)

      # All recipes also exercise ordinary local POST/first GET, with a local
      # route substituted for the declared source URL (including query/fragment).
      fixture = Gaoxy.Test.open()

      try do
        prefix = "/source-" <> expected.id
        post_path = prefix <> "/models/" <> model
        local = Map.put(config, :base_url, Gaoxy.Test.url(fixture, prefix))

        first_path =
          if expected.id == "synthesis-extract-all-keys-and-recursion",
            do: "/assets/key-1",
            else: "/assets/first"

        payload = localize_urls(row["response"]["payload"], fixture)

        assert_first_download(
          fixture,
          req,
          local,
          post_path,
          first_path,
          payload,
          Map.get(expected, :mime, "audio/mpeg"),
          body,
          result
        )
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "each exact URL key and recursive key wins over later source-ordered alternatives" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    url_keys = ~w(audioUrl audioUrls resultUrl resultUrls outputUrl outputUrls url urls)
    recursive_keys = ~w(output outputs result results data asset assets)

    vectors =
      Enum.with_index(url_keys)
      |> Enum.map(fn {key, index} ->
        {"key-" <> key,
         fn first, second ->
           later = Enum.drop(url_keys, index + 1) |> Map.new(&{&1, second})
           Map.put(later, key, [" #{first} ", [first, second]])
         end}
      end)

    vectors =
      vectors ++
        (Enum.with_index(recursive_keys)
         |> Enum.map(fn {key, index} ->
           {"recursive-" <> key,
            fn first, second ->
              later =
                Enum.drop(recursive_keys, index + 1)
                |> Map.new(&{&1, %{"audioUrl" => second}})

              Map.put(later, key, [%{"audioUrls" => [[" #{first} ", first, second]]}])
            end}
         end))

    assert length(vectors) == 15

    for {id, payload} <- vectors do
      prefix = "/ordered/" <> id
      first_path = prefix <> "/first"
      first = Gaoxy.Test.url(fixture, first_path)
      second = Gaoxy.Test.url(fixture, prefix <> "/second")
      config = Map.put(defaults(), :base_url, Gaoxy.Test.url(fixture, prefix))

      assert_first_download(
        fixture,
        request(),
        config,
        prefix <> "/models/elevenlabs/tts",
        first_path,
        payload.(first, second),
        "audio/mpeg",
        %{"text" => @text, "voice_id" => @voice},
        Map.put(mp3(), :audio, @audio)
      )
    end
  end

  test "both targets preserve independent case-sensitive format and normalized file metadata" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    for target <- [:audio_file, :voice_note],
        {id, mime, expected} <- [
          {"case", "Audio/WAV",
           %{
             output_format: "mp3",
             file_extension: ".wav",
             media_format: "wav",
             voice_compatible: false
           }},
          {"parameter", "audio/mpeg; name=wave",
           %{
             output_format: "wav",
             file_extension: ".mp3",
             media_format: "mp3",
             voice_compatible: false
           }},
          {"wave", "audio/wave",
           %{
             output_format: "wav",
             file_extension: ".wav",
             media_format: "wav",
             voice_compatible: false
           }}
        ] do
      prefix = "/mime/#{target}/#{id}"
      path = prefix <> "/audio"
      config = Map.put(defaults(), :base_url, Gaoxy.Test.url(fixture, prefix))

      assert_first_download(
        fixture,
        %{request() | target: target},
        config,
        prefix <> "/models/elevenlabs/tts",
        path,
        %{"audioUrl" => Gaoxy.Test.url(fixture, path)},
        mime,
        %{"text" => @text, "voice_id" => @voice},
        Map.put(expected, :audio, @audio)
      )
    end
  end

  test "ordinary HTTP uses two finite linked stages and clips both to one supplied absolute deadline" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    Code.ensure_loaded!(Req)
    for arity <- [1, 2], do: :erlang.trace_pattern({Req, :request, arity}, true, [:local])
    :erlang.trace_pattern({Task, :yield, 2}, true, [:local])

    try do
      Gaoxy.Test.stub(fixture, "POST", "/timing/models/elevenlabs/tts", fn conn ->
        json(conn, %{"audioUrl" => Gaoxy.Test.url(fixture, "/timing/audio")})
      end)

      Gaoxy.Test.stub(fixture, "GET", "/timing/audio", fn conn -> audio(conn, "audio/mpeg") end)
      config = Map.put(defaults(), :base_url, Gaoxy.Test.url(fixture, "/timing"))

      for {duration, native_remaining} <- [
            {12_345, nil},
            {45_000, nil},
            {75_000, nil},
            {45_000, 15_000}
          ] do
        caller = self()
        started = System.monotonic_time(:millisecond)
        deadline = if native_remaining, do: started + native_remaining
        req = Map.put(request(), :timeout_ms, duration)
        req = if deadline, do: Map.put(req, :deadline_ms, deadline), else: req

        service =
          Task.async(fn ->
            receive do
              :synthesize -> Vydra.synthesize(req, config)
            end
          end)

        :erlang.trace(service.pid, true, [:call, :procs, :set_on_spawn, {:tracer, caller}])
        send(service.pid, :synthesize)
        assert {:ok, result} = Task.await(service, 5000)
        assert result == Map.put(mp3(), :audio, @audio)
        barrier = :erlang.trace_delivered(:all)
        assert_receive {:trace_delivered, :all, ^barrier}, 1000
        events = drain_traces([])

        calls =
          for {:trace, pid, :call, {Req, :request, [%Req.Request{} = http | _]}} <- events,
              do: {pid, http}

        # Req.request/1 may delegate to /2; inspect the first call per wire method.
        stages = Enum.uniq_by(calls, fn {_pid, http} -> http.method end)
        assert Enum.map(stages, fn {_pid, http} -> http.method end) == [:post, :get]
        [{http_owner, _post}, {same_owner, _get}] = stages
        assert same_owner == http_owner
        refute http_owner == service.pid

        assert Enum.any?(events, fn
                 {:trace, pid, :link, child} -> pid == service.pid and child == http_owner
                 _ -> false
               end)

        waits =
          for {:trace, pid, :call, {Task, :yield, [%Task{pid: child}, timeout]}} <- events,
              pid == service.pid and child == http_owner,
              do: timeout

        assert [wait] = waits

        if native_remaining do
          assert wait > 0 and wait <= 15_000
        else
          assert wait == 2 * duration
        end

        for {_pid, http} <- stages do
          timeout = http.options.request_timeout
          assert is_integer(timeout) and timeout > 0 and timeout <= duration
          assert http.options.receive_timeout == timeout
          assert http.options.finch[:pool_timeout] == timeout
          if native_remaining, do: assert(timeout <= 15_000)
        end
      end
    after
      for arity <- [1, 2], do: :erlang.trace_pattern({Req, :request, arity}, false, [:local])
      :erlang.trace_pattern({Task, :yield, 2}, false, [:local])
    end
  end

  defp synthesis_cases do
    [
      %{id: "default-file"},
      %{id: "default-note"},
      %{id: "wav-file", mime: "audio/wav", result: wav()},
      %{id: "wav-note", mime: "audio/wav", result: wav()},
      %{id: "default-mime", mime: nil},
      %{
        id: "configured-model-voice",
        config: %{
          base_url: "https://speech.example.test/custom/v7",
          model: "custom/model",
          voice_id: "custom-voice"
        }
      },
      %{id: "override-model-voice", model: "custom/override", voice: "override-voice"},
      %{id: "blank-override-defaults"},
      %{id: "configured-namespace-retained", config: %{model: "vydra/elevenlabs/custom"}},
      %{
        id: "source-env-all",
        config: %{
          base_url: "https://env.example.test/voice",
          model: "env/model",
          voice_id: "env-voice"
        },
        explicit_source_env: %{
          "baseUrl" => "https://env.example.test/voice",
          "model" => "env/model",
          "voiceId" => "env-voice"
        }
      },
      %{
        id: "source-env-model",
        config: %{model: "env/model"},
        explicit_source_env: %{"model" => "env/model"}
      },
      %{
        id: "source-env-voice",
        config: %{voice_id: "env-voice"},
        explicit_source_env: %{"voiceId" => "env-voice"}
      },
      %{
        id: "configured-before-source-env",
        config: %{
          base_url: "https://speech.example.test/custom/v7",
          model: "custom/model",
          voice_id: "custom-voice"
        }
      },
      %{id: "canonical-root"},
      %{id: "custom-root", config: %{base_url: "https://voice.example.test/api/v1"}},
      %{id: "port-literal-url", config: %{base_url: "https://www.vydra.ai:8443/voice"}},
      %{
        id: "query-fragment-literal-url",
        config: %{base_url: "https://www.vydra.ai/api/v1?mode=voice#section"}
      },
      %{id: "unicode-config", config: %{voice_id: "Rachel-custom"}},
      %{id: "exact-authored-text", text: "  Ordinary speech.\n你好 🌍 — café.\t "},
      %{id: "synthesis-extract-root-priority"},
      %{id: "synthesis-extract-arrays"},
      %{id: "synthesis-extract-nested-order"},
      %{id: "synthesis-extract-ordered-dedup"},
      %{id: "synthesis-extract-all-keys-and-recursion"},
      %{id: "mpeg-parameters", mime: " audio/mpeg; codecs=mp3 "},
      %{id: "wav-parameters", mime: " audio/wav; codecs=pcm ", result: wav()},
      %{
        id: "wav-case-divergence",
        mime: "Audio/WAV",
        result: %{
          output_format: "mp3",
          file_extension: ".wav",
          media_format: "wav",
          voice_compatible: false
        }
      },
      %{
        id: "mpeg-parameter-divergence",
        mime: "audio/mpeg; name=wave",
        result: %{
          output_format: "wav",
          file_extension: ".mp3",
          media_format: "mp3",
          voice_compatible: false
        }
      },
      %{id: "x-wav", mime: "audio/x-wav", result: wav()},
      %{id: "flac-source-labels", mime: "audio/flac"},
      %{id: "octet-stream-source-labels", mime: "application/octet-stream"},
      %{id: "explicit-timeout-45000", timeout: 45_000},
      %{id: "explicit-timeout-75000-note", timeout: 75_000}
    ]
  end

  defp assert_first_download(
         fixture,
         req,
         config,
         post_path,
         first_path,
         payload,
         mime,
         body,
         result
       ) do
    owner = self()
    token = make_ref()

    Gaoxy.Test.expect_once(fixture, "POST", post_path, fn conn ->
      {:ok, data, conn} = Plug.Conn.read_body(conn)
      send(owner, {:vydra_http, token, "POST", conn.request_path, Jason.decode!(data)})
      json(conn, payload)
    end)

    Gaoxy.Test.expect_once(fixture, "GET", first_path, fn conn ->
      send(owner, {:vydra_http, token, "GET", conn.request_path})
      audio(conn, mime)
    end)

    assert {:ok, ^result} = Vydra.synthesize(req, config)
    assert_receive {:vydra_http, ^token, "POST", ^post_path, ^body}, 1000
    assert_receive {:vydra_http, ^token, "GET", ^first_path}, 1000
    refute_receive {:vydra_http, ^token, _, _}, 0
    refute_receive {:vydra_http, ^token, _, _, _}, 0
    assert :ok = Gaoxy.Test.verify!(fixture)
  end

  defp audio(conn, mime) do
    conn = if mime, do: Plug.Conn.put_resp_header(conn, "content-type", mime), else: conn
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, conn} = Plug.Conn.chunk(conn, <<82, 73, 70>>)
    {:ok, conn} = Plug.Conn.chunk(conn, <<70, 0, 1, 2, 255>>)
    conn
  end

  defp json(conn, payload),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))

  defp reference, do: @reference |> File.read!() |> Jason.decode!()

  defp defaults,
    do: %{api_key: "fixture-vydra-speech", base_url: @base, model: @model, voice_id: @voice}

  defp raw(fields),
    do: %{"providers" => %{"vydra" => Map.merge(%{"apiKey" => "fixture-vydra-speech"}, fields)}}

  defp request,
    do: %{text: @text, target: :audio_file, timeout_ms: 12_345, provider_overrides: %{}}

  defp target("audio-file"), do: :audio_file
  defp target("voice-note"), do: :voice_note

  defp mp3,
    do: %{
      output_format: "mp3",
      file_extension: ".mp3",
      media_format: "mp3",
      voice_compatible: false
    }

  defp wav,
    do: %{
      output_format: "wav",
      file_extension: ".wav",
      media_format: "wav",
      voice_compatible: false
    }

  defp source_config(config),
    do: %{
      api_key: config["apiKey"],
      base_url: config["baseUrl"],
      model: config["model"],
      voice_id: config["voiceId"]
    }

  defp source_overrides(config) do
    for {source, host} <- [{"model", :model}, {"voiceId", :voice_id}],
        Map.has_key?(config, source),
        into: %{},
        do: {host, config[source]}
  end

  defp source_result(result),
    do: %{
      audio: Base.decode64!(result["audioBase64"]),
      output_format: result["outputFormat"],
      file_extension: result["fileExtension"],
      voice_compatible: result["voiceCompatible"]
    }

  defp localize_urls(value, fixture) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, localize_urls(child, fixture)} end)

  defp localize_urls(value, fixture) when is_list(value),
    do: Enum.map(value, &localize_urls(&1, fixture))

  defp localize_urls(value, fixture) when is_binary(value),
    do: Gaoxy.Test.url(fixture, URI.parse(String.trim(value)).path)

  defp drain_traces(events) do
    receive do
      {:trace, _, _, _} = event -> drain_traces([event | events])
      {:trace, _, _, _, _} = event -> drain_traces([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
