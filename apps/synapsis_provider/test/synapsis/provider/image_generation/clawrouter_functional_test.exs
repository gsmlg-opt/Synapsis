defmodule Synapsis.Provider.ImageGeneration.ClawRouterFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.ClawRouter

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/clawrouter-image-generation.json",
               __DIR__
             )
  @reference_ids ~w(minimal fractional-timeout model-1 model-2 model-3 base-v1 base-prefix-trim count-1 count-2 count-3 count-4 count-5 count-6 count-7 count-8 count-9 count-10 fewer-results catalog-lowered-limits prompt-unicode-whitespace empty-references size-0 size-1 size-2 size-3 quality-0 quality-1 quality-2 quality-3 quality-4 quality-5 format-0 format-1 format-2 background-0 background-1 background-2 openai-options background-top-priority background-nullish inline-jpeg inline-webp explicit-png explicit-jpeg explicit-webp base64-unpadded base64-whitespace ordered-url-results repeat-fresh-catalog-first repeat-fresh-catalog-second source-only-default-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builder retains exact model and optional values with normalized explicit base" do
    req =
      Map.merge(request(), %{
        model: "openai/gpt-image-2.5-sunburst-2026-09-08",
        count: 2,
        size: "1024x1024",
        quality: "xhigh",
        output_format: "webp",
        background: "opaque",
        aspect_ratio: "16:9",
        resolution: "4K",
        provider_options: %{
          openai: %{
            background: "transparent",
            moderation: "low",
            output_compression: 0,
            user: " studio "
          }
        }
      })

    cfg = %{
      api_key: "synthetic-key",
      base_url: " https://router.example/custom/v1/// ",
      request: %{headers: %{"X-Context" => " studio "}}
    }

    assert {:ok, plan} = ClawRouter.build_request(req, cfg)
    assert plan.catalog_url == "https://router.example/custom/v1/catalog"
    assert plan.url == "https://router.example/custom/v1/images/generations"
    assert plan.model == "openai/gpt-image-2.5-sunburst-2026-09-08"
    assert plan.timeout_ms == 5_000
    assert plan.max_catalog_bytes == 1_048_576
    assert plan.max_image_bytes == 67_108_864
    assert plan.max_response_bytes == 180_005_547
    assert plan.max_downloads == 2
    assert plan.headers["x-context"] == "studio"
    assert plan.headers["x-clawrouter-client"] == "openclaw"
    assert plan.headers["content-type"] == "application/json"

    assert plan.body == %{
             "model" => "openai/gpt-image-2.5-sunburst-2026-09-08",
             "prompt" => " A mountain 雪\n",
             "n" => 2,
             "size" => "1024x1024",
             "quality" => "xhigh",
             "output_format" => "webp",
             "background" => "opaque",
             "moderation" => "low",
             "output_compression" => 0,
             "user" => " studio "
           }
  end

  test "fresh catalog precedes one POST and returns the complete ordered PNG result", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()
    png1 = <<137, 80, 78, 71, 13, 10, 26, 10, 1>>
    png2 = <<137, 80, 78, 71, 13, 10, 26, 10, 2>>

    Gaoxy.Test.expect_once(fixture, "GET", "/inline/v1/catalog", fn conn ->
      send(test_pid, :inline_catalog)
      json_response(conn, catalog())
    end)

    Gaoxy.Test.expect_once(fixture, "POST", "/inline/v1/images/generations", fn conn ->
      send(test_pid, :inline_post)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "model" => "openai/gpt-image-2.5-flare",
               "prompt" => " A mountain 雪\n",
               "n" => 2,
               "size" => "1024x1024"
             }

      assert Plug.Conn.get_req_header(conn, "x-clawrouter-client") == ["openclaw"]

      json_response(conn, %{
        "model" => "service-label",
        "usage" => %{"images" => 2},
        "data" => [
          %{
            "b64_json" => Base.encode64(png1),
            "mime_type" => " image/png ",
            "revised_prompt" => " revised mountain \n"
          },
          %{"b64_json" => Base.encode64(png2)}
        ]
      })
    end)

    assert {:ok, result} =
             generate(
               tasks,
               Map.merge(request(), %{count: 2, size: "1024x1024"}),
               config(Gaoxy.Test.url(fixture, "/inline"))
             )

    assert result == %{
             model: "openai/gpt-image-2.5-flare",
             images: [
               %{
                 data: png1,
                 mime_type: "image/png",
                 filename: "image-1.png",
                 revised_prompt: "revised mountain"
               },
               %{data: png2, mime_type: "image/png", filename: "image-2.png"}
             ]
           }

    assert_receive :inline_catalog
    assert_receive :inline_post
  end

  test "JPEG bytes determine omitted MIME and a smaller successful result retains model", %{
    fixture: fixture,
    tasks: tasks
  } do
    jpeg = <<255, 216, 255, 0, 1>>
    Gaoxy.Test.expect_once(fixture, "GET", "/jpeg/v1/catalog", &json_response(&1, catalog()))

    Gaoxy.Test.expect_once(fixture, "POST", "/jpeg/v1/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "model" => "openai/gpt-image-2.5-flare",
               "prompt" => " A mountain 雪\n",
               "n" => 2,
               "background" => "transparent",
               "output_compression" => 0
             }

      json_response(conn, %{
        "data" => [%{"b64_json" => Base.encode64(jpeg), "revised_prompt" => " snow "}]
      })
    end)

    req =
      Map.merge(request(), %{
        count: 2,
        background: nil,
        provider_options: %{openai: %{background: "transparent", output_compression: 0}}
      })

    assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, "/jpeg/v1/")))

    assert result == %{
             model: "openai/gpt-image-2.5-flare",
             images: [
               %{
                 data: jpeg,
                 mime_type: "image/jpeg",
                 filename: "image-1.jpg",
                 revised_prompt: "snow"
               }
             ]
           }
  end

  test "ordered WebP URL downloads finish within the normally exiting linked owner", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()
    webp1 = "RIFF0001WEBPone"
    webp2 = "RIFF0002WEBPtwo"
    Gaoxy.Test.expect_once(fixture, "GET", "/urls/v1/catalog", &json_response(&1, catalog()))

    Gaoxy.Test.expect_once(fixture, "POST", "/urls/v1/images/generations", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:post_waiting, self()})

      receive do
        :respond -> :ok
      after
        2_000 -> flunk("ordinary response was not released")
      end

      json_response(conn, %{
        "data" => [
          %{"url" => Gaoxy.Test.url(fixture, "/assets/first"), "revised_prompt" => " first "},
          %{"url" => Gaoxy.Test.url(fixture, "/assets/second")}
        ]
      })
    end)

    for {path, bytes, marker} <- [
          {"/assets/first", webp1, :first_download},
          {"/assets/second", webp2, :second_download}
        ] do
      Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
        send(test_pid, marker)

        conn
        |> Plug.Conn.put_resp_header("content-type", "Image/WebP; profile=ordinary")
        |> Plug.Conn.resp(200, bytes)
      end)
    end

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        ClawRouter.generate(
          Map.put(request(), :count, 2),
          config(Gaoxy.Test.url(fixture, "/urls"))
        )
      end)

    assert_receive {:post_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)

    assert result == %{
             model: "openai/gpt-image-2.5-flare",
             images: [
               %{
                 data: webp1,
                 mime_type: "image/webp",
                 filename: "image-1.webp",
                 revised_prompt: "first"
               },
               %{data: webp2, mime_type: "image/webp", filename: "image-2.webp"}
             ]
           }

    assert_receive :first_download
    assert_receive :second_download
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
  end

  test "repeated calls fetch fresh ordinary catalog limits before each POST", %{
    fixture: fixture,
    tasks: tasks
  } do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    calls = :atomics.new(2, [])

    Gaoxy.Test.expect(
      fixture,
      "GET",
      "/fresh/v1/catalog",
      fn conn ->
        count = :atomics.add_get(calls, 1, 1)
        json_response(conn, catalog(%{"maxImages" => count, "dimensionMultiple" => 16 * count}))
      end,
      times: 2
    )

    Gaoxy.Test.expect(
      fixture,
      "POST",
      "/fresh/v1/images/generations",
      fn conn ->
        count = :atomics.add_get(calls, 2, 1)
        assert :atomics.get(calls, 1) == count
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["n"] == count

        json_response(conn, %{
          "data" => List.duplicate(%{"b64_json" => Base.encode64(png)}, count)
        })
      end,
      times: 2
    )

    cfg = config(Gaoxy.Test.url(fixture, "/fresh"))

    for count <- 1..2 do
      assert {:ok, result} =
               generate(tasks, Map.merge(request(), %{count: count, size: "1024x1024"}), cfg)

      assert result == %{
               model: "openai/gpt-image-2.5-flare",
               images:
                 Enum.map(1..count, fn index ->
                   %{data: png, mime_type: "image/png", filename: "image-#{index}.png"}
                 end)
             }
    end

    assert :atomics.get(calls, 1) == 2
    assert :atomics.get(calls, 2) == 2
  end

  test "all 50 comparable pinned-source rows match plans, catalog, POST, downloads and full results",
       %{fixture: fixture, tasks: tasks} do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @reference_ids

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-default-timeout",
             "source-only-configured-header"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 50

    for {row, index} <- Enum.with_index(comparable, 1) do
      req = reference_request(row["input"])
      cfg = %{api_key: "synthetic-explicit-key", base_url: row["config"]["baseUrl"]}
      total_timeout = req.timeout_ms |> floor() |> max(1) |> min(2_147_000_000)
      assert {:ok, built} = ClawRouter.build_request(req, cfg)

      assert built == %{
               catalog_url: row["catalogRequest"]["url"],
               url: row["request"]["url"],
               catalog_headers: row["catalogRequest"]["headers"],
               headers: row["request"]["headers"],
               body: row["request"]["body"],
               model: row["input"]["model"],
               timeout_ms: total_timeout,
               max_catalog_bytes: row["catalogRequest"]["maxBytes"],
               max_image_bytes: 67_108_864,
               max_downloads: row["request"]["body"]["n"],
               max_response_bytes: row["request"]["maxBytes"]
             }

      assert row["inputAfter"] == row["input"]
      assert row["catalogRequest"]["releasedAtMs"] <= row["request"]["atMs"]

      # These are source synthetic stage budgets, independent of host wall-clock timing.
      for stage <-
            [row["catalogRequest"], row["request"]] ++ row["downloads"] ++ row["readerCalls"] do
        assert stage["timeoutMs"] == total_timeout - (stage["atMs"] - row["clock"]["startMs"])
        assert stage["timeoutMs"] > 0
      end

      for stage <- [row["catalogRequest"], row["request"]] ++ row["downloads"] do
        assert stage["releaseCount"] == 1
      end

      prefix = "/source-#{index}"
      phase = :atomics.new(1, [])

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/v1/catalog", fn conn ->
        assert :atomics.add_get(phase, 1, 1) == 1
        assert_protocol_headers(conn, row["catalogRequest"]["headers"])
        json_response(conn, row["catalogResponse"])
      end)

      payload = reference_downloads(fixture, prefix, row, phase)

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/v1/images/generations", fn conn ->
        assert :atomics.add_get(phase, 1, 1) == 2
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == row["request"]["body"]
        assert_protocol_headers(conn, row["request"]["headers"])
        json_response(conn, payload)
      end)

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"])
      assert :atomics.get(phase, 1) == 2 + length(row["downloads"])
      assert req == reference_request(row["inputAfter"])
    end
  end

  defp reference_request(input) do
    names = %{
      "prompt" => :prompt,
      "model" => :model,
      "timeoutMs" => :timeout_ms,
      "count" => :count,
      "size" => :size,
      "quality" => :quality,
      "outputFormat" => :output_format,
      "background" => :background,
      "inputImages" => :input_images
    }

    req =
      input
      |> Map.take(Map.keys(names))
      |> Map.new(fn {key, value} -> {Map.fetch!(names, key), value} end)

    case Map.fetch(input, "providerOptions") do
      :error ->
        req

      {:ok, options} ->
        fields = %{
          "background" => :background,
          "moderation" => :moderation,
          "outputCompression" => :output_compression,
          "user" => :user
        }

        openai =
          Map.new(options["openai"], fn {key, value} -> {Map.fetch!(fields, key), value} end)

        Map.put(req, :provider_options, %{openai: openai})
    end
  end

  defp assert_protocol_headers(conn, expected) do
    for name <- ["accept", "content-type", "x-clawrouter-client"], Map.has_key?(expected, name) do
      assert Plug.Conn.get_req_header(conn, name) == [expected[name]]
    end
  end

  defp reference_downloads(fixture, prefix, row, phase) do
    replacements =
      row["downloads"]
      |> Enum.with_index(1)
      |> Map.new(fn {download, index} ->
        assert download["method"] == "GET"
        assert download["headers"] == %{}
        assert download["maxBytes"] == 67_108_864
        assert row["request"]["releasedAtMs"] >= download["releasedAtMs"]
        binary = Enum.at(row["response"]["downloads"], index - 1)
        path = prefix <> "/asset-#{index}"

        Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
          assert :atomics.add_get(phase, 1, 1) == index + 2

          conn
          |> Plug.Conn.put_resp_header("content-type", binary["mimeType"])
          |> Plug.Conn.resp(200, Base.decode64!(binary["bytesBase64"]))
        end)

        {download["url"], Gaoxy.Test.url(fixture, path)}
      end)

    Map.update!(row["response"]["json"], "data", fn entries ->
      Enum.map(entries, fn entry ->
        case replacements[entry["url"]] do
          nil -> entry
          local_url -> Map.put(entry, "url", local_url)
        end
      end)
    end)
  end

  defp reference_result(result) do
    %{
      model: result["model"],
      images:
        Enum.map(result["images"], fn image ->
          asset = %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"]
          }

          case Map.fetch(image, "revisedPrompt") do
            :error -> asset
            {:ok, prompt} -> Map.put(asset, :revised_prompt, prompt)
          end
        end)
    }
  end

  defp request,
    do: %{prompt: " A mountain 雪\n", model: "openai/gpt-image-2.5-flare", timeout_ms: 5_000}

  defp config(base_url), do: %{api_key: "synthetic-key", base_url: base_url}

  defp generate(tasks, request, config),
    do:
      tasks
      |> Task.Supervisor.async_nolink(fn -> ClawRouter.generate(request, config) end)
      |> Task.await(10_000)

  defp json_response(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))

  defp catalog(overrides \\ %{}) do
    limits =
      Map.merge(
        %{
          "maxPromptCharacters" => 32_000,
          "maxImages" => 10,
          "dimensionMultiple" => 16,
          "minPixels" => 655_360,
          "maxPixels" => 8_294_400,
          "maxEdge" => 3_840,
          "maxAspectRatio" => 3
        },
        overrides
      )

    %{
      "version" => "clawrouter.client-catalog.v1",
      "providers" => [
        %{
          "id" => "openai",
          "allowed" => true,
          "executable" => true,
          "models" => [
            %{
              "id" => "openai/gpt-image-2.5-flare",
              "capabilities" => ["image.generation"],
              "pricing" => %{"unit" => "image_token", "generation" => limits}
            }
          ],
          "offers" => [
            %{
              "endpoint" => "images_generations",
              "modelId" => "openai/gpt-image-2.5-flare",
              "transport" => "http",
              "routeKind" => "unified",
              "route" => "/v1/images/generations",
              "eligible" => true,
              "affordability" => "exact-covered"
            }
          ]
        }
      ]
    }
  end
end
