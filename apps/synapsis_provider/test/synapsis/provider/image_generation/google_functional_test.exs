defmodule Synapsis.Provider.ImageGeneration.GoogleFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.Google

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/google-image-generation.json",
               __DIR__
             )
  @ids ~w(source-only-defaults explicit-default custom-model alias-gemini-3-pro alias-gemini-3-pro-preview alias-gemini-3-flash alias-gemini-3.1-pro alias-gemini-3.1-flash-lite-preview alias-gemini-3.1-flash alias-gemini-3.1-flash-preview alias-gemini-4 alias-gemma-4-26b alias-prefixed size-1024x1024 size-1024x1536 size-1536x1024 size-1024x1792 size-1792x1024 size-unmapped-small size-tier-2k size-tier-4k size-js-whitespace geometry-overrides-1k geometry-overrides-2k geometry-overrides-4k blank-aspect edit-one edit-five count-one count-four ignored-controls ordered-candidates mime-precedence base64-variants more-than-four larger-media-cap official-root-normalization official-uppercase-host)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builds one generation request with exact prompt and source geometry" do
    req = Map.merge(request(), %{size: " 1024X1536 ", count: 4})
    assert {:ok, built} = Google.build_request(req, config("https://images.example/v1beta/"))

    assert built.url ==
             "https://images.example/v1beta/models/gemini-3.1-flash-image:generateContent"

    assert built.model == "gemini-3.1-flash-image"
    assert built.timeout_ms == 5_000
    assert built.max_image_bytes == 64 * 1024 * 1024
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024

    assert built.body ==
             body([%{"text" => " A mountain 雪\n"}], %{"aspectRatio" => "2:3", "imageSize" => "2K"})
  end

  test "ordered edit bytes precede the prompt and explicit geometry overrides size" do
    req =
      Map.merge(request(), %{
        model: "\uFEFF google/gemini-3-pro \u00A0",
        size: "1792x1024",
        aspect_ratio: " 4:5 ",
        resolution: "4K",
        input_images: [
          %{data: <<0, 255, 1>>, mime_type: "image/jpeg; custom=raw", filename: "ignored.jpg"},
          %{data: "second", mime_type: "image/webp"}
        ]
      })

    assert {:ok, built} = Google.build_request(req, config("https://images.example/v1beta"))
    assert built.model == "google/gemini-3.1-pro-preview"

    assert built.body ==
             body(
               [
                 %{
                   "inlineData" => %{
                     "mimeType" => "image/jpeg; custom=raw",
                     "data" => Base.encode64(<<0, 255, 1>>)
                   }
                 },
                 %{
                   "inlineData" => %{
                     "mimeType" => "image/webp",
                     "data" => Base.encode64("second")
                   }
                 },
                 %{"text" => " A mountain 雪\n"}
               ],
               %{"aspectRatio" => "4:5", "imageSize" => "4K"}
             )
  end

  test "actual local POST preserves the generation body and returns only images and model", %{
    fixture: fixture,
    tasks: tasks
  } do
    expected = body([%{"text" => " A mountain 雪\n"}])

    response = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [%{"text" => "source text is ignored"}, inline("first", "image/png")]
          }
        }
      ],
      "usageMetadata" => %{"totalTokenCount" => 9},
      "other" => "ignored"
    }

    expect_json(
      fixture,
      "/v1beta/models/gemini-3.1-flash-image:generateContent",
      expected,
      response
    )

    assert {:ok, result} = generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/v1beta")))

    assert result == %{
             model: "gemini-3.1-flash-image",
             images: [%{data: "first", mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "flattens all candidates in order without truncating to count or advertised four", %{
    fixture: fixture,
    tasks: tasks
  } do
    response = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [
              inline("one", "image/jpeg"),
              %{"text" => "ignored"},
              %{"inline_data" => %{"data" => Base.encode64("two"), "mime_type" => "image/webp"}}
            ]
          }
        },
        %{
          "content" => %{
            "parts" => [
              inline("three", "image/svg+xml"),
              inline("four", "image/png"),
              inline("five", "image/gif")
            ]
          }
        }
      ]
    }

    expect_json(
      fixture,
      "/v1beta/models/gemini-3.1-flash-image:generateContent",
      body([%{"text" => request().prompt}]),
      response
    )

    assert {:ok, result} =
             generate(
               tasks,
               Map.put(request(), :count, 1),
               config(Gaoxy.Test.url(fixture, "/v1beta"))
             )

    assert result.images == [
             %{data: "one", mime_type: "image/jpeg", filename: "image-1.jpg"},
             %{data: "two", mime_type: "image/webp", filename: "image-2.webp"},
             %{data: "three", mime_type: "image/svg+xml", filename: "image-3.svg"},
             %{data: "four", mime_type: "image/png", filename: "image-4.png"},
             %{data: "five", mime_type: "image/gif", filename: "image-5.gif"}
           ]
  end

  test "all model aliases preserve exact case and recursively retain Google prefixes" do
    aliases = [
      {"gemini-3-pro", "gemini-3.1-pro-preview"},
      {"gemini-3-pro-preview", "gemini-3.1-pro-preview"},
      {"gemini-3-flash", "gemini-3-flash-preview"},
      {"gemini-3.1-pro", "gemini-3.1-pro-preview"},
      {"gemini-3.1-flash-lite-preview", "gemini-3.1-flash-lite"},
      {"gemini-3.1-flash", "gemini-3-flash-preview"},
      {"gemini-3.1-flash-preview", "gemini-3-flash-preview"},
      {"gemini-4", "gemini-4-argon"},
      {"gemma-4-26b", "gemma-4-26b-a4b-it"},
      {"Custom/IMAGE-v2", "Custom/IMAGE-v2"},
      {"Gemini-3-pro", "Gemini-3-pro"}
    ]

    for {input, expected} <- aliases, prefix <- ["", "google/", "google/google/"] do
      assert {:ok, built} =
               Google.build_request(
                 Map.put(request(), :model, "\uFEFF" <> prefix <> input <> "\u2029"),
                 config("https://images.example/v1beta")
               )

      assert built.model == prefix <> expected

      assert built.url ==
               "https://images.example/v1beta/models/" <> prefix <> expected <> ":generateContent"
    end
  end

  test "all geometry mappings and strict positive dimensions retain source precedence" do
    for {size, geometry} <- [
          {"1024x1024", %{"aspectRatio" => "1:1"}},
          {"1024x1536", %{"aspectRatio" => "2:3", "imageSize" => "2K"}},
          {"1536x1024", %{"aspectRatio" => "3:2", "imageSize" => "2K"}},
          {"1024x1792", %{"aspectRatio" => "9:16", "imageSize" => "2K"}},
          {"1792x1024", %{"aspectRatio" => "16:9", "imageSize" => "2K"}},
          {"1200x800", nil},
          {"2000x1000", %{"imageSize" => "2K"}},
          {"3072x1200", %{"imageSize" => "4K"}},
          {" +1536 x 01024 x extra", %{"imageSize" => "2K"}},
          {"\uFEFF1024X1536\u00A0", %{"aspectRatio" => "2:3", "imageSize" => "2K"}}
        ] do
      assert {:ok, built} =
               Google.build_request(
                 Map.put(request(), :size, size),
                 config("https://images.example/v1beta")
               )

      assert built.body == body([%{"text" => request().prompt}], geometry)
    end

    for resolution <- ["1K", "2K", "4K", " 4K "] do
      req =
        Map.merge(request(), %{
          size: "1024x1536",
          aspect_ratio: "\uFEFF21:9\u00A0",
          resolution: resolution
        })

      assert {:ok, built} = Google.build_request(req, config("https://images.example/v1beta"))

      assert built.body["generationConfig"]["imageConfig"] == %{
               "aspectRatio" => "21:9",
               "imageSize" => resolution
             }
    end

    assert {:ok, blank} =
             Google.build_request(
               Map.merge(request(), %{size: "1024x1024", aspect_ratio: " \n", resolution: ""}),
               config("https://images.example/v1beta")
             )

    assert blank.body["generationConfig"]["imageConfig"] == %{"aspectRatio" => "1:1"}
  end

  test "five actual edit inputs retain raw MIME and bytes while count and unsupported controls are ignored",
       %{fixture: fixture, tasks: tasks} do
    images =
      for n <- 1..5,
          do: %{
            data: <<n, 0, 255>>,
            mime_type: "image/WEBP; n=#{n}",
            filename: "unused-#{n}",
            url: "https://unused.example/#{n}"
          }

    req =
      Map.merge(request(), %{
        input_images: images,
        count: 4,
        quality: "high",
        output_format: "jpeg",
        background: "transparent",
        provider_options: %{google: %{extra: true}}
      })

    parts =
      Enum.map(images, fn image ->
        %{"inlineData" => %{"mimeType" => image.mime_type, "data" => Base.encode64(image.data)}}
      end) ++ [%{"text" => req.prompt}]

    expect_json(fixture, "/edit/models/gemini-3.1-flash-image:generateContent", body(parts), %{
      "candidates" => [%{"content" => %{"parts" => [inline("edited", "image/webp")]}}]
    })

    assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, "/edit")))

    assert result == %{
             model: request().model,
             images: [%{data: "edited", mime_type: "image/webp", filename: "image-1.webp"}]
           }
  end

  test "inline nullish precedence and MIME fallback preserve raw MIME without sniffing", %{
    fixture: fixture,
    tasks: tasks
  } do
    parts = [
      %{
        "inlineData" => nil,
        "inline_data" => %{"data" => Base.encode64("snake"), "mime_type" => " image/WEBP; q=1 "}
      },
      %{
        "inlineData" => %{
          "data" => Base.encode64("camel"),
          "mimeType" => " Image/JPEG; q=1 ",
          "mime_type" => "image/gif"
        },
        "inline_data" => %{"data" => Base.encode64("unused")}
      },
      %{
        "inlineData" => %{
          "data" => Base.encode64("fallback"),
          "mimeType" => " ",
          "mime_type" => " image/svg+xml "
        }
      },
      %{"inlineData" => %{"data" => Base.encode64(<<255, 216, 255, 0>>)}},
      %{"inlineData" => %{"data" => Base.encode64("opaque"), "mimeType" => "opaque"}}
    ]

    response = %{
      "candidates" => [
        %{},
        %{"content" => nil},
        %{"content" => %{}},
        %{"content" => %{"parts" => nil}},
        %{"content" => %{"parts" => [%{"text" => "ignored"}] ++ parts}}
      ]
    }

    expect_json(
      fixture,
      "/mime/models/gemini-3.1-flash-image:generateContent",
      body([%{"text" => request().prompt}]),
      response
    )

    assert {:ok, result} = generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/mime")))

    assert result.images == [
             %{data: "snake", mime_type: "image/WEBP; q=1", filename: "image-1.webp"},
             %{data: "camel", mime_type: "Image/JPEG; q=1", filename: "image-2.jpg"},
             %{data: "fallback", mime_type: "image/svg+xml", filename: "image-3.svg"},
             %{data: <<255, 216, 255, 0>>, mime_type: "image/png", filename: "image-4.png"},
             %{data: "opaque", mime_type: "opaque", filename: "image-5.png"}
           ]
  end

  test "canonical padded unpadded whitespace and URL-safe data return original bytes", %{
    fixture: fixture,
    tasks: tasks
  } do
    values = [
      {"YQ==", "a"},
      {"YWI", "ab"},
      {" \nY\tWJj\r ", "abc"},
      {"-_8", <<251, 255>>},
      {"-_8=", <<251, 255>>},
      {"Y\u0000Q==", "a"}
    ]

    parts = Enum.map(values, fn {data, _bytes} -> %{"inlineData" => %{"data" => data}} end)

    expect_json(
      fixture,
      "/base64/models/gemini-3.1-flash-image:generateContent",
      body([%{"text" => request().prompt}]),
      %{"candidates" => [%{"content" => %{"parts" => parts}}]}
    )

    assert {:ok, result} = generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/base64")))
    assert Enum.map(result.images, & &1.data) == Enum.map(values, &elem(&1, 1))
    assert Enum.map(result.images, & &1.filename) == Enum.map(1..6, &"image-#{&1}.png")
  end

  test "successful chunked raw response and image bytes reach their explicit host bounds", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = :binary.copy(<<0, 255, 128>>, 65_537)

    response =
      Jason.encode!(%{
        "candidates" => [%{"content" => %{"parts" => [inline(bytes, "image/webp")]}}]
      })

    Gaoxy.Test.expect_once(
      fixture,
      "POST",
      "/bounded/models/gemini-3.1-flash-image:generateContent",
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == body([%{"text" => request().prompt}])

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(chunks(response, 997), conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end
    )

    cfg =
      Map.merge(config(Gaoxy.Test.url(fixture, "/bounded")), %{
        max_image_bytes: byte_size(bytes),
        max_response_bytes: byte_size(response)
      })

    assert {:ok, result} = generate(tasks, request(), cfg)

    assert result == %{
             model: request().model,
             images: [%{data: bytes, mime_type: "image/webp", filename: "image-1.webp"}]
           }

    assert {:ok, built} =
             Google.build_request(
               request(),
               Map.put(cfg, :max_image_bytes, 96 * 1024 * 1024) |> Map.delete(:max_response_bytes)
             )

    assert built.max_response_bytes == div(96 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024
  end

  test "successful HTTP owner exits normally after its one POST", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    Gaoxy.Test.expect_once(
      fixture,
      "POST",
      "/owner/models/gemini-3.1-flash-image:generateContent",
      fn conn ->
        send(test_pid, {:http_waiting, self()})

        receive do
          :respond -> :ok
        after
          2_000 -> flunk("ordinary response was not released")
        end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "candidates" => [%{"content" => %{"parts" => [inline("normal", "image/png")]}}]
          })
        )
      end
    )

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        Google.generate(request(), config(Gaoxy.Test.url(fixture, "/owner")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    owners = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    assert [http_owner] = owners
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)
    assert result.images == [%{data: "normal", mime_type: "image/png", filename: "image-1.png"}]
    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all explicit fixed-source rows match complete builder plans and actual local HTTP", %{
    fixture: fixture,
    tasks: tasks
  } do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @ids
    source_only = Enum.filter(rows, &(not &1["hostComparable"]))
    assert Enum.map(source_only, & &1["id"]) == ["source-only-defaults"]
    assert hd(source_only)["request"]["timeoutMs"] == 180_000
    assert hd(source_only)["result"]["model"] == "gemini-3.1-flash-image"
    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 37

    for row <- comparable do
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = Google.build_request(req, cfg)
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert built.max_response_bytes == row["request"]["maxBytes"], row["id"]
      assert built.model == row["result"]["model"], row["id"]
      assert row["request"]["method"] == "POST", row["id"]
      assert row["releaseCount"] == 1, row["id"]
      assert row["inputAfter"] == row["input"], row["id"]
      prefix = "/reference/" <> row["id"]
      path = prefix <> "/models/" <> built.model <> ":generateContent"
      expect_json(fixture, path, row["request"]["body"], row["response"]["json"])

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"]), row["id"]
    end
  end

  defp reference_request(input) do
    req = %{prompt: input["prompt"], model: input["model"], timeout_ms: input["timeoutMs"]}

    req =
      Enum.reduce(
        [
          {"size", :size},
          {"aspectRatio", :aspect_ratio},
          {"resolution", :resolution},
          {"count", :count},
          {"quality", :quality},
          {"outputFormat", :output_format},
          {"background", :background},
          {"providerOptions", :provider_options}
        ],
        req,
        fn {key, atom}, acc ->
          if Map.has_key?(input, key), do: Map.put(acc, atom, input[key]), else: acc
        end
      )

    if images = input["inputImages"] do
      Map.put(
        req,
        :input_images,
        Enum.map(images, fn image ->
          %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"],
            url: image["url"]
          }
        end)
      )
    else
      req
    end
  end

  defp reference_config(input) do
    cfg = config(input["baseUrl"])

    if input["mediaMaxMb"],
      do: Map.put(cfg, :max_image_bytes, trunc(input["mediaMaxMb"] * 1024 * 1024)),
      else: cfg
  end

  defp reference_result(result) do
    %{
      model: result["model"],
      images:
        Enum.map(result["images"], fn image ->
          %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"]
          }
        end)
    }
  end

  defp chunks(<<>>, _size), do: []
  defp chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp chunks(bytes, size) do
    <<chunk::binary-size(size), rest::binary>> = bytes
    [chunk | chunks(rest, size)]
  end

  defp request,
    do: %{prompt: " A mountain 雪\n", model: "gemini-3.1-flash-image", timeout_ms: 5_000}

  defp config(base_url), do: %{api_key: "google-image-fixture", base_url: base_url}

  defp body(parts, geometry \\ nil) do
    generation = %{"responseModalities" => ["TEXT", "IMAGE"]}
    generation = if geometry, do: Map.put(generation, "imageConfig", geometry), else: generation
    %{"contents" => [%{"role" => "user", "parts" => parts}], "generationConfig" => generation}
  end

  defp inline(data, mime),
    do: %{"inlineData" => %{"data" => Base.encode64(data), "mimeType" => mime}}

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> Google.generate(request, config) end)
    |> Task.await(10_000)
  end

  defp expect_json(fixture, path, expected, response) do
    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == expected

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)
  end
end
