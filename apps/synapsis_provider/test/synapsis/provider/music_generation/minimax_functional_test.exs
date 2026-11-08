defmodule Synapsis.Provider.MusicGeneration.MiniMaxFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MusicGeneration.MiniMax

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "default and JS-blank models trim prompt and enable lyric optimization" do
    for extra <- [%{}, %{model: "\uFEFF \u00A0\n", lyrics: " \uFEFF\u00A0 "}] do
      request = Map.merge(%{prompt: "\uFEFF  夜の café 😀\n雪  \u00A0", timeout_ms: 12_345}, extra)

      assert {:ok, built} = MiniMax.build_request(request, config())

      assert without_authorization(built) === %{
               url: "https://api.minimax.io/v1/music_generation",
               model: "music-2.6",
               body: %{
                 "model" => "music-2.6",
                 "prompt" => "夜の café 😀\n雪",
                 "lyrics_optimizer" => true,
                 "stream" => true,
                 "output_format" => "hex",
                 "audio_setting" => %{
                   "sample_rate" => 44_100,
                   "bitrate" => 256_000,
                   "format" => "mp3"
                 }
               },
               headers: %{"content-type" => "application/json"},
               timeout_ms: 12_345,
               max_audio_bytes: 16_777_216,
               max_response_bytes: 83_951_616,
               result_metadata: %{instrumental: false}
             }
    end
  end

  test "portal uses the configured origin, preserves trimmed model prefix and ignores duration" do
    request = %{
      prompt: "\uFEFF 星と雪 😀\nfinal \u00A0",
      model: "\uFEFF minimax/music-cover \u00A0",
      timeout_ms: 8_765,
      lyrics: "\uFEFF First  line\n第二行 😀 \u00A0",
      instrumental: false,
      duration_seconds: 37.5,
      format: "mp3",
      input_images: []
    }

    cfg = %{
      api_key: "fixture-key",
      provider_id: "minimax-portal",
      base_url: "\uFEFF https://music.example:8443/relay/path?source=fixture#fragment \u00A0",
      max_audio_bytes: 123_456,
      max_response_bytes: 234_567,
      request: %{
        headers: %{"X-Context" => " ordinary music ", "Content-Type" => "text/plain"}
      }
    }

    assert {:ok, built} = MiniMax.build_request(request, cfg)

    assert without_authorization(built) === %{
             url: "https://music.example:8443/v1/music_generation",
             model: "minimax/music-cover",
             body: %{
               "model" => "minimax/music-cover",
               "prompt" => "星と雪 😀\nfinal",
               "lyrics" => "First  line\n第二行 😀",
               "stream" => true,
               "output_format" => "hex",
               "audio_setting" => %{
                 "sample_rate" => 44_100,
                 "bitrate" => 256_000,
                 "format" => "mp3"
               }
             },
             headers: %{
               "content-type" => "application/json",
               "x-context" => "ordinary music"
             },
             timeout_ms: 8_765,
             max_audio_bytes: 123_456,
             max_response_bytes: 234_567,
             result_metadata: %{instrumental: false, requested_lyrics: true}
           }
  end

  test "both provider IDs use instrumental bodies and audio-derived envelope capacity" do
    for provider_id <- ["minimax", "minimax-portal"] do
      assert {:ok, built} =
               MiniMax.build_request(
                 %{
                   prompt: " instrumental 雪 😀 ",
                   model: " music-2.6-free ",
                   timeout_ms: 5_000,
                   instrumental: true,
                   lyrics: "\uFEFF \u00A0",
                   duration_seconds: 90,
                   format: "mp3"
                 },
                 %{api_key: "fixture-key", provider_id: provider_id, max_audio_bytes: 4_096}
               )

      assert without_authorization(built) === %{
               url: "https://api.minimax.io/v1/music_generation",
               model: "music-2.6-free",
               body: %{
                 "model" => "music-2.6-free",
                 "prompt" => "instrumental 雪 😀",
                 "is_instrumental" => true,
                 "stream" => true,
                 "output_format" => "hex",
                 "audio_setting" => %{
                   "sample_rate" => 44_100,
                   "bitrate" => 256_000,
                   "format" => "mp3"
                 }
               },
               headers: %{"content-type" => "application/json"},
               timeout_ms: 5_000,
               max_audio_bytes: 4_096,
               max_response_bytes: 86_016,
               result_metadata: %{instrumental: true}
             }
    end
  end

  test "direct audio preserves raw MIME parameters and every opaque HTTP chunk", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    chunks = for n <- 0..15, do: :binary.copy(<<n, 255, 128, 0>>, 17)

    expect_post(
      fixture,
      %{
        "model" => "music-2.6",
        "prompt" => "direct 音楽 😀",
        "lyrics_optimizer" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      " Audio/WAVE; source=fixture ",
      chunks,
      owner
    )

    assert generate(tasks, %{prompt: " direct 音楽 😀 ", timeout_ms: 5_000}, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: IO.iodata_to_binary(chunks),
                    mime_type: "Audio/WAVE; source=fixture",
                    filename: "track-1.wav"
                  }
                ],
                model: "music-2.6",
                metadata: %{instrumental: false}
              }}

    verify_requests(fixture)
  end

  test "JSON top-level inline hex and hexadecimal lyrics keep exact first-track metadata", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json_post(
      fixture,
      %{
        "model" => "music-cover",
        "prompt" => "sing 雪 😀",
        "lyrics" => "Verse one",
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      %{
        "audio" => "\uFEFF 00ff801122 \u00A0",
        "lyrics" => "20204e6967687420e6ad8c20f09f98800a56657273652020",
        "task_id" => "\uFEFF job-雪 😀 \u00A0",
        "base_resp" => %{"status_code" => 0, "status_msg" => "ordinary success"},
        "data" => %{"audio" => "deadbeef", "lyrics" => "nested lyrics"},
        "usage" => %{"tokens" => 42}
      },
      owner
    )

    request = %{
      prompt: " sing 雪 😀 ",
      model: " music-cover ",
      timeout_ms: 5_000,
      lyrics: "\uFEFF Verse one \u00A0",
      format: "mp3"
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128, 17, 34>>,
                    mime_type: "audio/mpeg",
                    filename: "track-1.mp3"
                  }
                ],
                model: "music-cover",
                lyrics: ["Night 歌 😀\nVerse"],
                metadata: %{
                  instrumental: false,
                  requested_lyrics: true,
                  task_id: "job-雪 😀"
                }
              }}

    verify_requests(fixture)
  end

  test "JSON nested inline audio and plain lyrics retain instrumental request context", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json_post(
      fixture,
      %{
        "model" => "music-cover-free",
        "prompt" => "instrumental 雪",
        "is_instrumental" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      %{
        "audio" => "\uFEFF \u00A0",
        "data" => %{
          "audio" => " fF0080 ",
          "lyrics" => "\uFEFF Returned plain 歌 😀 \u00A0"
        }
      },
      owner
    )

    request = %{
      prompt: " instrumental 雪 ",
      model: "music-cover-free",
      timeout_ms: 5_000,
      instrumental: true,
      lyrics: " \uFEFF "
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<255, 0, 128>>, mime_type: "audio/mpeg", filename: "track-1.mp3"}
                ],
                model: "music-cover-free",
                lyrics: ["Returned plain 歌 😀"],
                metadata: %{instrumental: true}
              }}

    verify_requests(fixture)
  end

  test "explicit JSON audio URL wins other candidates and download retains raw MIME without track URL",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    owner = self()
    url = Gaoxy.Test.url(fixture, "/tracks/selected")
    chunks = [<<0, 255, 128>>, <<17, 34, 51>>, <<254, 0>>]

    expect_json_post(
      fixture,
      %{
        "model" => "music-2.6",
        "prompt" => "download 夜 😀",
        "lyrics_optimizer" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      %{
        "audio_url" => "\uFEFF " <> url <> " \u00A0",
        "audio" => "00ff801122",
        "data" => %{"audio_url" => Gaoxy.Test.url(fixture, "/tracks/other")},
        "lyrics" => "  Downloaded 歌 😀  ",
        "task_id" => "  task-download  "
      },
      owner
    )

    expect_download(fixture, "/tracks/selected", " Audio/FLAC; mode=fixture ", chunks, owner)

    cfg = http_config(fixture) |> Map.put(:provider_id, "minimax-portal")

    assert generate(tasks, %{prompt: " download 夜 😀 ", timeout_ms: 5_000}, cfg) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128, 17, 34, 51, 254, 0>>,
                    mime_type: "Audio/FLAC; mode=fixture",
                    filename: "track-1.flac"
                  }
                ],
                model: "music-2.6",
                lyrics: ["Downloaded 歌 😀"],
                metadata: %{
                  instrumental: false,
                  task_id: "task-download",
                  audio_url: url
                }
              }}

    verify_requests(fixture, "/tracks/selected")
  end

  test "nested URL audio candidate uses default download MIME and omits blank response metadata",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    owner = self()
    url = Gaoxy.Test.url(fixture, "/tracks/nested")

    expect_json_post(
      fixture,
      %{
        "model" => "music-2.6",
        "prompt" => "nested URL 歌",
        "lyrics_optimizer" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      %{
        "data" => %{"audio" => " " <> url <> " ", "lyrics" => " \uFEFF "},
        "task_id" => " \u00A0 "
      },
      owner
    )

    expect_download(fixture, "/tracks/nested", nil, [<<255, 128, 0, 42>>], owner)

    assert generate(tasks, %{prompt: " nested URL 歌 ", timeout_ms: 5_000}, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<255, 128, 0, 42>>, mime_type: "audio/mpeg", filename: "track-1.mp3"}
                ],
                model: "music-2.6",
                metadata: %{instrumental: false, audio_url: url}
              }}

    verify_requests(fixture, "/tracks/nested")
  end

  test "successful SSE joins incremental hex while completion aggregate is not appended", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    stream =
      "event: music\r\n" <>
        "data: {\"data\":{\"audio\":\"00fF\",\"status\":1},\"base_resp\":{\"status_code\":0,\"status_msg\":\"成功 😀\"}}\r\n" <>
        "data: {\"data\":{\"audio\":\"801122\",\"status\":\"1\"}}\r\n" <>
        "data: {\"data\":{\"audio\":\"00ff801122\",\"status\":2}}\r\n" <>
        "data: [DONE]"

    expect_post(
      fixture,
      %{
        "model" => "music-2.6",
        "prompt" => "stream 音楽 😀",
        "lyrics_optimizer" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      "Text/Event-Stream; charset=utf-8",
      byte_chunks(stream, 7),
      owner
    )

    assert generate(tasks, %{prompt: " stream 音楽 😀 ", timeout_ms: 5_000}, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128, 17, 34>>,
                    mime_type: "audio/mpeg",
                    filename: "track-1.mp3"
                  }
                ],
                model: "music-2.6",
                metadata: %{instrumental: false}
              }}

    verify_requests(fixture)
  end

  test "a first successful completion frame supplies the single audio track", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_post(
      fixture,
      %{
        "model" => "music-2.6-free",
        "prompt" => "completion 夜",
        "is_instrumental" => true,
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{
          "sample_rate" => 44_100,
          "bitrate" => 256_000,
          "format" => "mp3"
        }
      },
      "text/event-stream",
      ["data: {\"data\":{\"audio\":\"FF00802A\",\"status\":\"2\"}}\n\n", "data: [DONE]\n"],
      owner
    )

    request = %{
      prompt: " completion 夜 ",
      model: "music-2.6-free",
      timeout_ms: 5_000,
      instrumental: true
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<255, 0, 128, 42>>, mime_type: "audio/mpeg", filename: "track-1.mp3"}
                ],
                model: "music-2.6-free",
                metadata: %{instrumental: true}
              }}

    verify_requests(fixture)
  end

  defp expect_json_post(fixture, expected_body, payload, owner),
    do: expect_post(fixture, expected_body, "application/json", [Jason.encode!(payload)], owner)

  defp expect_post(fixture, expected_body, mime, chunks, owner) do
    Gaoxy.Test.expect_once(fixture, "POST", "/v1/music_generation", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) === expected_body
      assert Plug.Conn.get_req_header(conn, "content-type") === ["application/json"]
      send(owner, {:minimax_request, :post})
      send_chunks(conn, mime, chunks)
    end)
  end

  defp expect_download(fixture, path, mime, chunks, owner) do
    Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
      send(owner, {:minimax_request, {:get, path}})
      send_chunks(conn, mime, chunks)
    end)
  end

  defp send_chunks(conn, mime, chunks) do
    conn = if mime, do: Plug.Conn.put_resp_header(conn, "content-type", mime), else: conn
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn chunk, acc ->
      {:ok, next} = Plug.Conn.chunk(acc, chunk)
      next
    end)
  end

  defp verify_requests(fixture, download_path \\ nil) do
    assert_receive {:minimax_request, :post}, 1_000
    if download_path, do: assert_receive({:minimax_request, {:get, ^download_path}}, 1_000)
    Gaoxy.Test.verify!(fixture)
  end

  defp byte_chunks("", _size), do: []

  defp byte_chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp byte_chunks(bytes, size) do
    <<head::binary-size(size), tail::binary>> = bytes
    [head | byte_chunks(tail, size)]
  end

  defp without_authorization(built),
    do: Map.update!(built, :headers, &Map.delete(&1, "authorization"))

  defp generate(tasks, request, cfg) do
    task = Task.Supervisor.async_nolink(tasks, fn -> MiniMax.generate(request, cfg) end)
    Task.await(task, 10_000)
  end

  defp config, do: %{api_key: "fixture-key"}

  defp http_config(fixture),
    do: %{
      api_key: "fixture-key",
      base_url: Gaoxy.Test.url(fixture, "/discarded/path?source=fixture#fragment")
    }
end
