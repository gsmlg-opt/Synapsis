defmodule Synapsis.Provider.MusicGeneration.GoogleFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MusicGeneration.Google

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "default and JS-blank models use the clip route and trim the prompt" do
    for extra <- [%{}, %{model: "\uFEFF \u00A0\n", lyrics: " \uFEFF\u00A0 "}] do
      request = Map.merge(%{prompt: "\uFEFF  夜の café 😀\n雪  \u00A0", timeout_ms: 12_345}, extra)

      assert Google.build_request(request, config()) ===
               {:ok,
                %{
                  url:
                    "https://generativelanguage.googleapis.com/v1beta/models/lyria-3-clip-preview:generateContent",
                  body: %{
                    "contents" => [
                      %{"role" => "user", "parts" => [%{"text" => "夜の café 😀\n雪"}]}
                    ],
                    "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
                  },
                  model: "lyria-3-clip-preview",
                  timeout_ms: 12_345,
                  max_audio_bytes: 16_777_216,
                  max_response_bytes: 67_108_864,
                  result_metadata: %{input_image_count: 0, instrumental: false}
                }}
    end
  end

  test "Pro composes instrumental and lyrics together before ordered references without format wire fields" do
    request = %{
      prompt: "\uFEFF 星と雪 😀\nfinal \u00A0",
      model: "\uFEFF lyria-3-pro-preview \u00A0",
      timeout_ms: 8_765,
      lyrics: "\uFEFF First  line\n第二行 😀 \u00A0",
      instrumental: true,
      duration_seconds: 37.5,
      format: "wav",
      input_images: [
        %{data: <<0, 255, 128>>, filename: "ignored-first.png"},
        %{data: <<1, 2, 3, 4>>, mime_type: "\uFEFF Image/WebP; Mode=raw \u00A0"}
      ]
    }

    cfg = %{
      api_key: "fixture-key",
      base_url:
        "\uFEFF https://GENERATIVELANGUAGE.GOOGLEAPIS.COM/v1beta/openai///?source=fixture#fragment \u00A0",
      max_audio_bytes: 123_456,
      max_response_bytes: 234_567
    }

    assert Google.build_request(request, cfg) ===
             {:ok,
              %{
                url:
                  "https://generativelanguage.googleapis.com/v1beta/models/lyria-3-pro-preview:generateContent",
                body: %{
                  "contents" => [
                    %{
                      "role" => "user",
                      "parts" => [
                        %{
                          "text" =>
                            "星と雪 😀\nfinal\n\nInstrumental only. No vocals, no sung lyrics, no spoken word.\n\nLyrics:\nFirst  line\n第二行 😀"
                        },
                        %{"inlineData" => %{"mimeType" => "image/png", "data" => "AP+A"}},
                        %{
                          "inlineData" => %{
                            "mimeType" => "Image/WebP; Mode=raw",
                            "data" => "AQIDBA=="
                          }
                        }
                      ]
                    }
                  ],
                  "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
                },
                model: "lyria-3-pro-preview",
                timeout_ms: 8_765,
                max_audio_bytes: 123_456,
                max_response_bytes: 234_567,
                result_metadata: %{
                  input_image_count: 2,
                  instrumental: true,
                  requested_lyrics: true,
                  requested_format: "wav"
                }
              }}
  end

  test "SDK model resource routes preserve models, tunedModels, provider prefixes and nonmusic aliases" do
    for {model, resource} <- [
          {"models/lyria-3-clip-preview", "models/lyria-3-clip-preview"},
          {"tunedModels/custom-song", "tunedModels/custom-song"},
          {"google/lyria-3-pro-preview", "models/google/lyria-3-pro-preview"},
          {"gemini-3-pro", "models/gemini-3-pro"}
        ] do
      request = %{
        prompt: " route 歌 😀 ",
        model: "\uFEFF " <> model <> " \u00A0",
        timeout_ms: 5_000
      }

      cfg = %{api_key: "fixture-key", base_url: "https://music.example/root/v1beta///"}

      assert Google.build_request(request, cfg) ===
               {:ok,
                %{
                  url: "https://music.example/root/v1beta/" <> resource <> ":generateContent",
                  body: %{
                    "contents" => [
                      %{"role" => "user", "parts" => [%{"text" => "route 歌 😀"}]}
                    ],
                    "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
                  },
                  model: model,
                  timeout_ms: 5_000,
                  max_audio_bytes: 16_777_216,
                  max_response_bytes: 67_108_864,
                  result_metadata: %{input_image_count: 0, instrumental: false}
                }}
    end
  end

  test "ordinary POST keeps seven reference images after the prompt in their original order", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json(
      fixture,
      "/v1beta/models/lyria-3-clip-preview:generateContent",
      %{
        "contents" => [
          %{
            "role" => "user",
            "parts" => [
              %{"text" => "seven references 歌 😀"},
              %{"inlineData" => %{"mimeType" => "image/png", "data" => "AA=="}},
              %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => "AQ=="}},
              %{
                "inlineData" => %{"mimeType" => "Image/WebP; quality=raw", "data" => "Ag=="}
              },
              %{"inlineData" => %{"mimeType" => "image/png", "data" => "Aw=="}},
              %{"inlineData" => %{"mimeType" => "image/png", "data" => "BA=="}},
              %{"inlineData" => %{"mimeType" => "image/avif", "data" => "BQ=="}},
              %{"inlineData" => %{"mimeType" => "IMAGE/PNG", "data" => "Bg=="}}
            ]
          }
        ],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"inlineData" => %{"mimeType" => "audio/mpeg", "data" => "AP+A"}}]
            }
          }
        ]
      },
      owner
    )

    request = %{
      prompt: " seven references 歌 😀 ",
      timeout_ms: 5_000,
      input_images: [
        %{data: <<0>>, filename: "ignored.png"},
        %{data: <<1>>, mime_type: "\uFEFF image/jpeg \u00A0"},
        %{data: <<2>>, mime_type: " Image/WebP; quality=raw "},
        %{data: <<3>>, mime_type: ""},
        %{data: <<4>>, mime_type: " \uFEFF "},
        %{data: <<5>>, mime_type: "image/avif"},
        %{data: <<6>>, mime_type: "IMAGE/PNG"}
      ]
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<0, 255, 128>>, mime_type: "audio/mpeg", filename: "track-1.mp3"}
                ],
                model: "lyria-3-clip-preview",
                metadata: %{input_image_count: 7, instrumental: false}
              }}

    verify_post(fixture)
  end

  test "all candidates retain ordered tracks and lyrics while nonblank text wins in its part", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json(
      fixture,
      "/v1beta/models/lyria-3-clip-preview:generateContent",
      %{
        "contents" => [
          %{"role" => "user", "parts" => [%{"text" => "ordered candidates 夜 😀"}]}
        ],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "\uFEFF Intro lyric 歌 \u00A0",
                  "inlineData" => %{"mimeType" => "audio/flac", "data" => "AA=="}
                },
                %{"inlineData" => %{"mimeType" => " Audio/WAV; rate=44100 ", "data" => "AP+A"}},
                %{"thought" => true},
                %{
                  "text" => " \uFEFF ",
                  "inlineData" => %{
                    "mime_type" => " audio/ogg ; codecs=opus ",
                    "data" => "ESIz"
                  }
                }
              ]
            }
          },
          %{
            "content" => %{
              "parts" => [
                %{"text" => "  Second line\n歌 😀  "},
                %{"inline_data" => %{"mime_type" => "audio/flac", "data" => "REVG"}}
              ]
            }
          },
          %{"content" => %{}},
          %{"content" => %{"parts" => [%{"inlineData" => %{"data" => "R0hJ"}}]}}
        ],
        "usageMetadata" => %{"totalTokenCount" => 42},
        "modelVersion" => "response-model-is-not-the-requested-model",
        "responseId" => "ignored-id"
      },
      owner
    )

    assert generate(
             tasks,
             %{prompt: " ordered candidates 夜 😀 ", timeout_ms: 5_000},
             http_config(fixture)
           ) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128>>,
                    mime_type: "Audio/WAV; rate=44100",
                    filename: "track-1.wav"
                  },
                  %{
                    data: <<17, 34, 51>>,
                    mime_type: "audio/ogg ; codecs=opus",
                    filename: "track-2.ogg"
                  },
                  %{data: "DEF", mime_type: "audio/flac", filename: "track-3.flac"},
                  %{data: "GHI", mime_type: "audio/mpeg", filename: "track-4.mp3"}
                ],
                model: "lyria-3-clip-preview",
                lyrics: ["Intro lyric 歌", "Second line\n歌 😀"],
                metadata: %{input_image_count: 0, instrumental: false}
              }}

    verify_post(fixture)
  end

  test "successful audio parts accept padded, unpadded, URL-safe and control-whitespace Base64",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    owner = self()

    expect_json(
      fixture,
      "/v1beta/models/lyria-3-clip-preview:generateContent",
      %{
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "Base64 歌 😀"}]}],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"inlineData" => %{"data" => "AP+A/w=="}},
                %{"inlineData" => %{"data" => "AQIDBA"}},
                %{"inline_data" => %{"data" => "-_8"}},
                %{"inlineData" => %{"data" => " \u0000A\tP+\rA\n"}}
              ]
            }
          }
        ]
      },
      owner
    )

    assert generate(tasks, %{prompt: " Base64 歌 😀 ", timeout_ms: 5_000}, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<0, 255, 128, 255>>, mime_type: "audio/mpeg", filename: "track-1.mp3"},
                  %{data: <<1, 2, 3, 4>>, mime_type: "audio/mpeg", filename: "track-2.mp3"},
                  %{data: <<251, 255>>, mime_type: "audio/mpeg", filename: "track-3.mp3"},
                  %{data: <<0, 255, 128>>, mime_type: "audio/mpeg", filename: "track-4.mp3"}
                ],
                model: "lyria-3-clip-preview",
                metadata: %{input_image_count: 0, instrumental: false}
              }}

    verify_post(fixture)
  end

  test "inline nullish precedence and MIME fallback retain the complete successful parts", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json(
      fixture,
      "/v1beta/models/lyria-3-clip-preview:generateContent",
      %{
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "MIME 音楽"}]}],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "inlineData" => nil,
                  "inline_data" => %{
                    "data" => "AQ==",
                    "mimeType" => " \uFEFF ",
                    "mime_type" => " Audio/WAVE; mode=fixture "
                  }
                },
                %{
                  "inlineData" => %{},
                  "inline_data" => %{"data" => "CQ==", "mime_type" => "audio/flac"}
                },
                %{
                  "inlineData" => %{
                    "data" => "Ag==",
                    "mimeType" => " Audio/FLAC ",
                    "mime_type" => "audio/wav"
                  },
                  "inline_data" => %{"data" => "CA==", "mime_type" => "audio/wav"}
                },
                %{"inline_data" => %{"data" => "Aw==", "mime_type" => " \u00A0 "}}
              ]
            }
          }
        ]
      },
      owner
    )

    assert generate(tasks, %{prompt: " MIME 音楽 ", timeout_ms: 5_000}, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<1>>,
                    mime_type: "Audio/WAVE; mode=fixture",
                    filename: "track-1.wav"
                  },
                  %{data: <<2>>, mime_type: "Audio/FLAC", filename: "track-2.flac"},
                  %{data: <<3>>, mime_type: "audio/mpeg", filename: "track-3.mp3"}
                ],
                model: "lyria-3-clip-preview",
                metadata: %{input_image_count: 0, instrumental: false}
              }}

    verify_post(fixture)
  end

  test "exact Pro model uses WAV filename fallback while format remains metadata only", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    expect_json(
      fixture,
      "/v1beta/models/lyria-3-pro-preview:generateContent",
      %{
        "contents" => [
          %{
            "role" => "user",
            "parts" => [
              %{
                "text" =>
                  "Pro theme 歌\n\nInstrumental only. No vocals, no sung lyrics, no spoken word.\n\nLyrics:\nVerse one\n第二行"
              }
            ]
          }
        ],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "\uFEFF Returned verse 😀 \u00A0"},
                %{"inlineData" => %{"data" => "AQI=", "mimeType" => " application/x-music "}},
                %{"inline_data" => %{"data" => "AwQ=", "mime_type" => "audio/x-custom"}}
              ]
            }
          }
        ]
      },
      owner
    )

    request = %{
      prompt: " Pro theme 歌 ",
      model: " lyria-3-pro-preview ",
      timeout_ms: 5_000,
      instrumental: true,
      lyrics: "\uFEFF Verse one\n第二行 \u00A0",
      format: "wav",
      duration_seconds: 48.5
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<1, 2>>, mime_type: "application/x-music", filename: "track-1.wav"},
                  %{data: <<3, 4>>, mime_type: "audio/x-custom", filename: "track-2.wav"}
                ],
                model: "lyria-3-pro-preview",
                lyrics: ["Returned verse 😀"],
                metadata: %{
                  input_image_count: 0,
                  instrumental: true,
                  requested_lyrics: true,
                  requested_format: "wav"
                }
              }}

    verify_post(fixture)
  end

  test "prefixed Pro identifiers retain their SDK route and use the nonexact MP3 fallback", %{
    fixture: fixture,
    tasks: tasks
  } do
    for {model, route} <- [
          {"google/lyria-3-pro-preview", "models/google/lyria-3-pro-preview"},
          {"models/lyria-3-pro-preview", "models/lyria-3-pro-preview"}
        ] do
      owner = self()

      expect_json(
        fixture,
        "/v1beta/" <> route <> ":generateContent",
        %{
          "contents" => [%{"role" => "user", "parts" => [%{"text" => "prefix 音楽"}]}],
          "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
        },
        %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"inlineData" => %{"data" => "AP+A", "mimeType" => "audio/x-custom"}}
                ]
              }
            }
          ]
        },
        owner
      )

      request = %{prompt: " prefix 音楽 ", model: model, timeout_ms: 5_000, format: "mp3"}

      assert generate(tasks, request, http_config(fixture)) ===
               {:ok,
                %{
                  tracks: [
                    %{data: <<0, 255, 128>>, mime_type: "audio/x-custom", filename: "track-1.mp3"}
                  ],
                  model: model,
                  metadata: %{
                    input_image_count: 0,
                    instrumental: false,
                    requested_format: "mp3"
                  }
                }}

      verify_post(fixture)
    end
  end

  test "chunked JSON preserves Unicode lyrics and complete opaque audio on a tuned model route",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    owner = self()
    bytes = :binary.copy(IO.iodata_to_binary(for n <- 0..255, do: <<n>>), 3)

    response = %{
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "content" => %{
            "parts" => [
              %{"text" => "  夜の café 😀\n歌  "},
              %{
                "inlineData" => %{
                  "data" => Base.encode64(bytes),
                  "mimeType" => " Audio/MP4; codec=synthetic "
                }
              }
            ]
          }
        }
      ],
      "usageMetadata" => %{"totalTokenCount" => 17}
    }

    expect_post(
      fixture,
      "/v1beta/tunedModels/custom-song:generateContent",
      %{
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "chunked 夜 😀"}]}],
        "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
      },
      byte_chunks(Jason.encode!(response), 7),
      owner
    )

    request = %{
      prompt: " chunked 夜 😀 ",
      model: "\uFEFF tunedModels/custom-song \u00A0",
      timeout_ms: 5_000
    }

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: bytes,
                    mime_type: "Audio/MP4; codec=synthetic",
                    filename: "track-1.m4a"
                  }
                ],
                model: "tunedModels/custom-song",
                lyrics: ["夜の café 😀\n歌"],
                metadata: %{input_image_count: 0, instrumental: false}
              }}

    verify_post(fixture)
  end

  test "ordinary finite timeout sends the SDK server timeout seconds header", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    path = "/v1beta/models/lyria-3-clip-preview:generateContent"

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) === %{
               "contents" => [
                 %{"role" => "user", "parts" => [%{"text" => "server timeout 歌 😀"}]}
               ],
               "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
             }

      assert Plug.Conn.get_req_header(conn, "x-server-timeout") === ["13"]
      send(owner, {:google_music_request, path})

      payload = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"inlineData" => %{"data" => "AP+A", "mimeType" => "audio/mpeg"}}]
            }
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    request = %{prompt: " server timeout 歌 😀 ", timeout_ms: 12_345}

    assert generate(tasks, request, http_config(fixture)) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<0, 255, 128>>, mime_type: "audio/mpeg", filename: "track-1.mp3"}
                ],
                model: "lyria-3-clip-preview",
                metadata: %{input_image_count: 0, instrumental: false}
              }}

    verify_post(fixture)
  end

  defp expect_json(fixture, path, expected_body, payload, owner),
    do: expect_post(fixture, path, expected_body, [Jason.encode!(payload)], owner)

  defp expect_post(fixture, path, expected_body, chunks, owner) do
    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) === expected_body
      send(owner, {:google_music_request, path})

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(chunks, conn, fn chunk, acc ->
        {:ok, next} = Plug.Conn.chunk(acc, chunk)
        next
      end)
    end)
  end

  defp verify_post(fixture) do
    assert_receive {:google_music_request, _path}, 1_000
    Gaoxy.Test.verify!(fixture)
  end

  defp byte_chunks("", _size), do: []
  defp byte_chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp byte_chunks(bytes, size) do
    <<head::binary-size(size), tail::binary>> = bytes
    [head | byte_chunks(tail, size)]
  end

  defp generate(tasks, request, cfg) do
    task = Task.Supervisor.async_nolink(tasks, fn -> Google.generate(request, cfg) end)
    Task.await(task, 10_000)
  end

  defp config, do: %{api_key: "fixture-key"}

  defp http_config(fixture),
    do: %{api_key: "fixture-key", base_url: Gaoxy.Test.url(fixture, "/")}
end
