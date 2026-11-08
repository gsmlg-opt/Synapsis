defmodule Synapsis.Provider.MusicGeneration.FalFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MusicGeneration.Fal

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "default and JS-blank models preserve prompt bytes and enable the source lyric optimizer" do
    for extra <- [%{}, %{model: "\uFEFF \u00A0\n"}] do
      request = Map.merge(%{prompt: "  夜の café 😀\n雪  ", timeout_ms: 12_345}, extra)

      assert Fal.build_request(request, config()) ==
               {:ok,
                %{
                  url: "https://fal.run/fal-ai/minimax-music/v2.6",
                  model: "fal-ai/minimax-music/v2.6",
                  body: %{
                    "prompt" => "  夜の café 😀\n雪  ",
                    "lyrics_optimizer" => true,
                    "audio_setting" => %{
                      "sample_rate" => 44_100,
                      "bitrate" => 256_000,
                      "format" => "mp3"
                    }
                  },
                  headers: %{
                    "authorization" => "Key fixture-key",
                    "content-type" => "application/json"
                  },
                  timeout_ms: 12_345,
                  max_audio_bytes: 16_777_216,
                  max_response_bytes: 16_777_216,
                  result_metadata: %{instrumental: false}
                }}
    end
  end

  test "MiniMax keeps the full prompt and model prefix with trimmed lyrics and fractional duration" do
    request = %{
      prompt: "  星と雪 😀\nfinal  ",
      model: "\uFEFF fal/fal-ai/custom-music \u00A0",
      timeout_ms: 8_765,
      lyrics: "\uFEFF First  line\n第二行 😀 \u00A0",
      instrumental: false,
      duration_seconds: 37.5,
      format: "mp3",
      input_images: []
    }

    cfg = %{
      api_key: "fixture-key",
      base_url: "\uFEFF https://music.example/relay/// \u00A0",
      max_audio_bytes: 123_456,
      max_response_bytes: 234_567,
      request: %{headers: %{"X-Context" => " ordinary 音楽 "}}
    }

    assert Fal.build_request(request, cfg) ==
             {:ok,
              %{
                url: "https://music.example/relay/fal/fal-ai/custom-music",
                model: "fal/fal-ai/custom-music",
                body: %{
                  "prompt" => "  星と雪 😀\nfinal  ",
                  "lyrics" => "First  line\n第二行 😀",
                  "duration" => 37.5,
                  "audio_setting" => %{
                    "sample_rate" => 44_100,
                    "bitrate" => 256_000,
                    "format" => "mp3"
                  }
                },
                headers: %{
                  "authorization" => "Key fixture-key",
                  "content-type" => "application/json",
                  "x-context" => "ordinary 音楽"
                },
                timeout_ms: 8_765,
                max_audio_bytes: 123_456,
                max_response_bytes: 234_567,
                result_metadata: %{
                  instrumental: false,
                  requested_format: "mp3",
                  requested_duration_seconds: 37.5
                }
              }}
  end

  test "ACE instrumental and Stable Audio select their distinct source duration fields" do
    for {model, instrumental, expected_body} <- [
          {"fal-ai/ace-step/prompt-to-audio", true,
           %{"prompt" => "音楽 😀", "instrumental" => true, "duration" => 23.75}},
          {"fal-ai/stable-audio-25/text-to-audio", false,
           %{"prompt" => "音楽 😀", "seconds_total" => 23.75}}
        ] do
      assert {:ok, built} =
               Fal.build_request(
                 %{
                   prompt: "音楽 😀",
                   model: "\u00A0" <> model <> "\uFEFF",
                   timeout_ms: 9_000,
                   instrumental: instrumental,
                   lyrics: "\uFEFF \u00A0",
                   duration_seconds: 23.75,
                   format: "wav"
                 },
                 config()
               )

      assert built == %{
               url: "https://fal.run/" <> model,
               model: model,
               body: expected_body,
               headers: %{
                 "authorization" => "Key fixture-key",
                 "content-type" => "application/json"
               },
               timeout_ms: 9_000,
               max_audio_bytes: 16_777_216,
               max_response_bytes: 16_777_216,
               result_metadata: %{
                 instrumental: instrumental,
                 requested_format: "wav",
                 requested_duration_seconds: 23.75
               }
             }
    end
  end

  test "ordinary POST downloads only the first candidate and retains Unicode lyrics and source metadata",
       %{fixture: fixture, tasks: tasks} do
    owner = self()
    url = Gaoxy.Test.url(fixture, "/tracks/first")
    bytes = <<0, 255, 128, 1, 2, 3, 254>>

    expect_post(
      fixture,
      "/relay/fal-ai/minimax-music/v2.6",
      %{
        "prompt" => "  sing 雪 😀  ",
        "lyrics" => "Verse  one\n第二行",
        "duration" => 37.5,
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      %{
        "audio" => %{
          "url" => "\uFEFF " <> url <> " \u00A0",
          "content_type" => "audio/flac",
          "file_name" => "\uFEFF 雪の café.wav \u00A0"
        },
        "audio_file" => Gaoxy.Test.url(fixture, "/tracks/second"),
        "lyrics" => "\uFEFF Returned  verse\n歌 😀 \u00A0",
        "seed" => 0,
        "tags" => [%{"label" => "夜", "weight" => 0.25}, nil, "café"]
      },
      owner
    )

    expect_download(fixture, "/tracks/first", " Audio/WAV; source=fixture ", [bytes], owner)

    request = %{
      prompt: "  sing 雪 😀  ",
      timeout_ms: 5_000,
      lyrics: "\u00A0 Verse  one\n第二行 \uFEFF",
      duration_seconds: 37.5
    }

    assert generate(tasks, request, http_config(fixture)) ==
             {:ok,
              %{
                tracks: [
                  %{
                    data: bytes,
                    mime_type: "audio/wav",
                    filename: "雪の café.wav",
                    metadata: %{url: url}
                  }
                ],
                model: "fal-ai/minimax-music/v2.6",
                lyrics: ["Returned  verse\n歌 😀"],
                metadata: %{
                  audio_url: url,
                  instrumental: false,
                  seed: 0,
                  tags: [%{"label" => "夜", "weight" => 0.25}, nil, "café"],
                  requested_duration_seconds: 37.5
                }
              }}

    assert_receive {:fal_request, :post}, 1_000
    assert_receive {:fal_request, {:get, "/tracks/first"}}, 1_000
    Gaoxy.Test.verify!(fixture)
  end

  test "ACE string audio uses MPEG defaults while nil optional source metadata stays omitted", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    url = Gaoxy.Test.url(fixture, "/tracks/ace")
    bytes = <<255, 0, 128, 17, 19>>

    expect_post(
      fixture,
      "/relay/fal-ai/ace-step/prompt-to-audio",
      %{"prompt" => "instrumental 雪", "instrumental" => true, "duration" => 24},
      %{"audio" => " " <> url <> " ", "lyrics" => " \uFEFF", "seed" => nil, "tags" => nil},
      owner
    )

    expect_download(fixture, "/tracks/ace", "application/octet-stream", [bytes], owner)

    request = %{
      prompt: "instrumental 雪",
      model: "fal-ai/ace-step/prompt-to-audio",
      timeout_ms: 5_000,
      instrumental: true,
      duration_seconds: 24,
      format: "wav"
    }

    assert generate(tasks, request, http_config(fixture)) ==
             {:ok,
              %{
                tracks: [
                  %{
                    data: bytes,
                    mime_type: "audio/mpeg",
                    filename: "track-1.mp3",
                    metadata: %{url: url}
                  }
                ],
                model: "fal-ai/ace-step/prompt-to-audio",
                metadata: %{
                  audio_url: url,
                  instrumental: true,
                  requested_format: "wav",
                  requested_duration_seconds: 24
                }
              }}

    assert_receive {:fal_request, :post}, 1_000
    assert_receive {:fal_request, {:get, "/tracks/ace"}}, 1_000
    Gaoxy.Test.verify!(fixture)
  end

  test "Stable audio_file uses candidate MIME and preserves complete ordinary chunked bytes", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    url = Gaoxy.Test.url(fixture, "/tracks/stable")
    chunks = for n <- 0..15, do: :binary.copy(<<n, 255, 128>>, 19)
    bytes = IO.iodata_to_binary(chunks)

    expect_post(
      fixture,
      "/relay/fal-ai/stable-audio-25/text-to-audio",
      %{"prompt" => "安定した 音楽 😀", "seconds_total" => 18.125},
      %{
        "audio_file" => %{
          "url" => "\u00A0" <> url <> "\uFEFF",
          "content_type" => " Audio/FLAC; source=candidate "
        },
        "tags" => %{"mood" => ["calm", "雪"], "optional" => nil}
      },
      owner
    )

    expect_download(fixture, "/tracks/stable", "binary/octet-stream", chunks, owner)

    request = %{
      prompt: "安定した 音楽 😀",
      model: "fal-ai/stable-audio-25/text-to-audio",
      timeout_ms: 5_000,
      instrumental: false,
      duration_seconds: 18.125,
      format: "wav",
      input_images: []
    }

    assert generate(tasks, request, http_config(fixture)) ==
             {:ok,
              %{
                tracks: [
                  %{
                    data: bytes,
                    mime_type: "audio/flac",
                    filename: "track-1.flac",
                    metadata: %{url: url}
                  }
                ],
                model: "fal-ai/stable-audio-25/text-to-audio",
                metadata: %{
                  audio_url: url,
                  instrumental: false,
                  tags: %{"mood" => ["calm", "雪"], "optional" => nil},
                  requested_format: "wav",
                  requested_duration_seconds: 18.125
                }
              }}

    assert_receive {:fal_request, :post}, 1_000
    assert_receive {:fal_request, {:get, "/tracks/stable"}}, 1_000
    Gaoxy.Test.verify!(fixture)
  end

  defp expect_post(fixture, path, expected_body, payload, owner) do
    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) === expected_body
      send(owner, {:fal_request, :post})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp expect_download(fixture, path, mime, chunks, owner) do
    Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
      send(owner, {:fal_request, {:get, path}})

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", mime)
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(chunks, conn, fn chunk, acc ->
        {:ok, next} = Plug.Conn.chunk(acc, chunk)
        next
      end)
    end)
  end

  defp generate(tasks, request, cfg) do
    task = Task.Supervisor.async_nolink(tasks, fn -> Fal.generate(request, cfg) end)
    Task.await(task, 10_000)
  end

  defp config, do: %{api_key: "fixture-key"}

  defp http_config(fixture),
    do: %{api_key: "fixture-key", base_url: Gaoxy.Test.url(fixture, "/relay")}
end
