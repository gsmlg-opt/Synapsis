defmodule Synapsis.Provider.MusicGeneration.OpenRouterFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MusicGeneration.OpenRouter

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openrouter-music-generation.json",
               __DIR__
             )
  @external_resource @reference

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builds the source default music request with a finite explicit host budget" do
    assert {:ok, built} = OpenRouter.build_request(request(), config())

    assert built == %{
             url: "https://openrouter.ai/api/v1/chat/completions",
             model: "google/lyria-3-pro-preview",
             format: "wav",
             input_image_count: 0,
             instrumental: false,
             timeout_ms: 12_345,
             max_audio_bytes: 16_777_216,
             body: %{
               "model" => "google/lyria-3-pro-preview",
               "messages" => [%{"role" => "user", "content" => "雪の歌 🎵"}],
               "modalities" => ["text", "audio"],
               "audio" => %{"format" => "wav"},
               "stream" => true
             }
           }
  end

  test "composes JS-trimmed prompt lyrics instrumental and rounded duration in source order" do
    input =
      Map.merge(request(), %{
        model: "\uFEFF Vendor/Music-X \u00A0",
        format: "mp3",
        instrumental: true,
        lyrics: "\u00A0 First  line\n第二行 😀 \uFEFF",
        duration_seconds: 42.5,
        seed: 99,
        provider_options: %{ignored: true}
      })

    assert {:ok, built} =
             OpenRouter.build_request(input, %{
               api_key: "fixture-key",
               base_url: " https://music.example/v2/// ",
               max_audio_bytes: 999
             })

    assert built.url == "https://music.example/v2/chat/completions"
    assert built.model == "Vendor/Music-X"
    assert built.format == "mp3"
    assert built.max_audio_bytes == 999

    assert built.body == %{
             "model" => "Vendor/Music-X",
             "messages" => [
               %{
                 "role" => "user",
                 "content" =>
                   "雪の歌 🎵\n\nInstrumental only. No vocals, no sung lyrics, no spoken word.\n\nLyrics:\nFirst  line\n第二行 😀\n\nTarget duration: about 43 seconds."
               }
             ],
             "modalities" => ["text", "audio"],
             "audio" => %{"format" => "mp3"},
             "stream" => true
           }
  end

  test "reference image URL wins and bytes use source default or trimmed MIME" do
    for {image, url} <- [
          {%{url: " https://image.example/雪.png ", data: <<1, 2, 3>>},
           "https://image.example/雪.png"},
          {%{data: <<0, 255, 128>>}, "data:image/png;base64,AP+A"},
          {%{data: <<0, 255, 128>>, mime_type: " image/webp "}, "data:image/webp;base64,AP+A"}
        ] do
      assert {:ok, built} =
               OpenRouter.build_request(Map.put(request(), :input_images, [image]), config())

      assert built.input_image_count == 1

      assert built.body["messages"] == [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "雪の歌 🎵"},
                   %{"type" => "image_url", "image_url" => %{"url" => url}}
                 ]
               }
             ]
    end
  end

  test "stream preserves one base64 stream across arbitrary deltas and UTF8 network chunks", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<0, 255, 128, 1, 2, 3, 254>>
    encoded = Base.encode64(bytes)
    <<one::binary-size(1), two::binary-size(2), rest::binary>> = encoded

    body =
      ":keepalive\r\n\r\n" <>
        event(%{
          "choices" => [%{"delta" => %{"audio" => %{"data" => one, "transcript" => "  歌 😀"}}}]
        }) <>
        event(%{
          "choices" => [%{"delta" => %{"audio" => %{"data" => two, "transcript" => "\nline  "}}}]
        }) <>
        event(%{"choices" => [%{"delta" => %{"audio" => %{"data" => rest}}}]}) <>
        "data: [DONE]\r\n"

    expected = result(bytes, "wav", "  歌 😀\nline  ")
    assert_http(fixture, tasks, request(), body, expected, :bytes)
  end

  test "final unterminated DONE flushes unpadded base64 and keeps the requested model", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<250, 1, 2, 3, 4>>

    body =
      event(%{
        "model" => "server-model",
        "choices" => [
          %{
            "delta" => %{
              "audio" => %{
                "data" => Base.encode64(bytes, padding: false),
                "transcript" => "\n "
              }
            }
          }
        ]
      }) <> "data: [DONE]"

    req = Map.merge(request(), %{format: "mp3", model: " Custom/Clip "})

    assert_http(
      fixture,
      tasks,
      req,
      body,
      %{result(bytes, "mp3", "\n ") | model: "Custom/Clip"},
      :whole
    )
  end

  test "ordinary many-line stream succeeds at independent audio and transcript byte caps", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = :binary.copy(<<0, 255, 128>>, 32_768)
    transcript = String.duplicate("歌", 32_768)

    body =
      for <<chunk::binary-size(512) <- Base.encode64(bytes)>>,
        into: "",
        do: event(%{"choices" => [%{"delta" => %{"audio" => %{"data" => chunk}}}]})

    body =
      body <>
        event(%{"choices" => [%{"delta" => %{"audio" => %{"transcript" => transcript}}}]}) <>
        "data: [DONE]\n"

    assert byte_size(bytes) == byte_size(transcript)

    assert_http(
      fixture,
      tasks,
      request(),
      body,
      result(bytes, "wav", transcript),
      :blocks,
      byte_size(bytes)
    )
  end

  for row <- Jason.decode!(File.read!(@reference))["observations"],
      row["hostComparable"] != false do
    test "pinned source request and actual HTTP result: #{row["id"]}", %{
      fixture: fixture,
      tasks: tasks
    } do
      row = unquote(Macro.escape(row))
      req = oracle_request(row["input"])
      [cap_call] = row["maxBytesCalls"]
      cfg = Map.merge(config(), %{max_audio_bytes: cap_call["maxBytes"]})
      cfg = if base = row["config"]["baseUrl"], do: Map.put(cfg, :base_url, base), else: cfg

      assert {:ok, built} = OpenRouter.build_request(req, cfg)
      assert built.url == row["request"]["url"]
      assert built.body == row["request"]["jsonBody"]
      assert built.timeout_ms == row["request"]["timeoutMs"]
      assert built.max_audio_bytes == cap_call["maxBytes"]

      chunks = Enum.map(row["response"]["chunksBase64"], &Base.decode64!/1)

      assert_http(
        fixture,
        tasks,
        req,
        IO.iodata_to_binary(chunks),
        oracle_result(row["result"]),
        {:source_chunks, chunks},
        cap_call["maxBytes"]
      )
    end
  end

  defp oracle_request(input) do
    keys = %{
      "prompt" => :prompt,
      "model" => :model,
      "timeoutMs" => :timeout_ms,
      "format" => :format,
      "lyrics" => :lyrics,
      "instrumental" => :instrumental,
      "durationSeconds" => :duration_seconds
    }

    request =
      for {source, target} <- keys,
          Map.has_key?(input, source),
          into: %{},
          do: {target, input[source]}

    case input["inputImages"] do
      nil ->
        request

      images ->
        Map.put(
          request,
          :input_images,
          Enum.map(images, fn image ->
            image_keys = %{"url" => :url, "mimeType" => :mime_type}

            fields =
              for {source, target} <- image_keys,
                  Map.has_key?(image, source),
                  into: %{},
                  do: {target, image[source]}

            if data = image["bytesBase64"],
              do: Map.put(fields, :data, Base.decode64!(data)),
              else: fields
          end)
        )
    end
  end

  defp oracle_result(value) do
    result = %{
      tracks:
        Enum.map(value["tracks"], fn track ->
          %{
            data: Base.decode64!(track["bytesBase64"]),
            mime_type: track["mimeType"],
            filename: track["fileName"]
          }
        end),
      model: value["model"],
      metadata: %{
        input_image_count: value["metadata"]["inputImageCount"],
        instrumental: value["metadata"]["instrumental"],
        requested_format: value["metadata"]["requestedFormat"]
      }
    }

    if lyrics = value["lyrics"], do: Map.put(result, :lyrics, lyrics), else: result
  end

  defp request, do: %{prompt: "\uFEFF\u00A0 雪の歌 🎵 \n", timeout_ms: 12_345}
  defp config, do: %{api_key: "fixture-key"}
  defp event(value), do: "data: " <> Jason.encode!(value) <> "\r\n\r\n"

  defp result(bytes, format, lyrics) do
    %{
      model: "google/lyria-3-pro-preview",
      tracks: [
        %{
          data: bytes,
          mime_type: if(format == "mp3", do: "audio/mpeg", else: "audio/wav"),
          filename: "track-1.#{format}"
        }
      ],
      lyrics: [lyrics],
      metadata: %{input_image_count: 0, instrumental: false, requested_format: format}
    }
  end

  defp assert_http(fixture, tasks, req, body, expected, mode, limit \\ 16_777_216) do
    assert {:ok, built} = OpenRouter.build_request(req, config())
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/music/chat/completions", fn conn ->
      {:ok, wire, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(wire) == built.body
      send(owner, {:music_request, built.body})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      chunks =
        case mode do
          :bytes -> for <<byte <- body>>, do: <<byte>>
          :blocks -> chunks(body, 997)
          :whole -> [body]
          {:source_chunks, chunks} -> chunks
        end

      Enum.reduce(chunks, conn, fn chunk, acc ->
        {:ok, next} = Plug.Conn.chunk(acc, chunk)
        next
      end)
    end)

    cfg = %{
      api_key: "fixture-key",
      base_url: Gaoxy.Test.url(fixture, "/music"),
      max_audio_bytes: limit
    }

    task = Task.Supervisor.async_nolink(tasks, fn -> OpenRouter.generate(req, cfg) end)
    assert Task.await(task, 20_000) == {:ok, expected}
    assert_receive {:music_request, body_sent}, 1_000
    assert body_sent == built.body
    Gaoxy.Test.verify!(fixture)
  end

  defp chunks("", _size), do: []
  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size) do
    <<head::binary-size(size), rest::binary>> = data
    [head | chunks(rest, size)]
  end
end
