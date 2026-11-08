defmodule Synapsis.Provider.ImageGeneration.OpenRouterFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.ImageGeneration.OpenRouter

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openrouter-image-generation.json",
               __DIR__
             )
  @external_resource @reference
  @ids ~w(default-count canonical-trailing-slashes legacy-root legacy-js-trim canonical-js-trim model-prompt-js-trim prefixed-model-geometry-ignored non-gemini-geometry-ignored dedicated-four-reverse-completion custom-chat-count-four aspect-1-1 aspect-2-3 aspect-3-2 aspect-3-4 aspect-4-3 aspect-4-5 aspect-5-4 aspect-9-16 aspect-16-9 aspect-21-9 resolution-1K resolution-2K resolution-4K chat-gemini-trimmed-geometry input-one-default-png input-five-raw-bytes-mime-name chat-input-five dedicated-sniff-and-explicit-mime dedicated-media-type-alias-precedence chat-message-images-then-content-string chat-content-array-image-url-variants chat-base64-and-inline-variants chat-valid-precedence chat-choice-order-contiguous-filenames base64-unpadded base64-whitespace chat-data-url-case-parameters media-cap-floor media-cap-larger-chat-four source-only-default-model-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "canonical and legacy roots use dedicated single-image requests with exact model prefix" do
    req = Map.merge(request(), %{count: 3.9, aspect_ratio: " 16:9 ", resolution: " 2K "})

    for root <- ["\uFEFF https://openrouter.ai/api/v1/// \u00A0", "https://openrouter.ai/v1/"] do
      assert {:ok, built} = OpenRouter.build_request(req, config(root))

      assert built == %{
               url: "https://openrouter.ai/api/v1/images",
               model: "google/gemini-test",
               mode: :dedicated,
               request_count: 3,
               headers: %{"authorization" => "Bearer synthetic-explicit-key"},
               timeout_ms: 5_000,
               max_image_bytes: 64 * 1024 * 1024,
               max_response_bytes: div(64 * 1024 * 1024 * 4 + 2, 3) + 1024 * 1024,
               body: %{
                 "model" => "google/gemini-test",
                 "prompt" => " A mountain 雪\n",
                 "n" => 1,
                 "aspect_ratio" => "16:9",
                 "resolution" => "2K"
               }
             }
    end

    assert {:ok, prefixed} =
             OpenRouter.build_request(
               Map.merge(req, %{model: " openrouter/google/gemini-test ", count: 4}),
               config("https://openrouter.ai/api/v1")
             )

    assert prefixed.request_count == 4

    assert prefixed.body == %{
             "model" => "openrouter/google/gemini-test",
             "prompt" => " A mountain 雪\n",
             "n" => 1
           }
  end

  test "custom chat preserves five reference bytes and full ordered image parts", ctx do
    req =
      Map.merge(request(), %{
        count: 4,
        aspect_ratio: " 4:3 ",
        resolution: " 4K ",
        size: "unused",
        quality: "high",
        background: "transparent",
        provider_options: %{unused: true},
        input_images: [
          %{data: <<0, 255, 128>>, filename: "ignored.png"},
          %{data: "two", mime_type: " Image/JPEG "},
          %{data: "three", mime_type: " image/webp "},
          %{data: "four", mime_type: "\uFEFF image/avif \u00A0"},
          %{data: "five", mime_type: " image/png "}
        ]
      })

    expected = %{
      "model" => "google/gemini-test",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => " A mountain 雪\n"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AP+A"}},
            %{"type" => "image_url", "image_url" => %{"url" => "data:Image/JPEG;base64,dHdv"}},
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/webp;base64,dGhyZWU="}
            },
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/avif;base64,Zm91cg=="}
            },
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,Zml2ZQ=="}}
          ]
        }
      ],
      "modalities" => ["image", "text"],
      "n" => 4,
      "image_config" => %{"aspect_ratio" => "4:3", "image_size" => "4K"}
    }

    cfg =
      Map.put(config("https://images.example/custom///"), :request, %{
        headers: %{"X-Profile" => " studio "}
      })

    assert {:ok, built} = OpenRouter.build_request(req, cfg)
    assert built.url == "https://images.example/custom/chat/completions"
    assert built.mode == :chat
    assert built.request_count == 1
    assert built.body == expected

    assert built.headers == %{
             "authorization" => "Bearer synthetic-explicit-key",
             "x-profile" => "studio"
           }

    assert built.max_response_bytes == div(64 * 1024 * 1024 * 8 * 4 + 2, 3) + 1024 * 1024

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/parts/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == expected
      assert Plug.Conn.get_req_header(conn, "content-type") == ["text/plain;charset=UTF-8"]
      assert Plug.Conn.get_req_header(conn, "x-profile") == ["studio"]

      json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "images" => [
                %{"image_url" => nil, "imageUrl" => %{"url" => "data:image/jpeg;base64,b25l"}}
              ],
              "content" => [
                %{"type" => "text", "text" => "ignored"},
                %{"type" => "image_url", "imageUrl" => %{"url" => "data:image/webp;base64,dHdv"}},
                %{"b64_json" => "dGhyZWU"}
              ]
            }
          },
          %{
            "message" => %{
              "content" => [
                %{"inline_data" => %{"data" => "Zm91cg==", "mime_type" => " Image/AVIF "}}
              ]
            }
          }
        ]
      })
    end)

    assert {:ok, result} =
             generate(
               ctx.tasks,
               req,
               Map.put(cfg, :base_url, Gaoxy.Test.url(ctx.fixture, "/parts"))
             )

    assert result == %{
             model: "google/gemini-test",
             images: [
               %{data: "one", mime_type: "image/jpeg", filename: "image-1.jpg"},
               %{data: "two", mime_type: "image/webp", filename: "image-2.webp"},
               %{data: "three", mime_type: "image/png", filename: "image-3.png"},
               %{data: "four", mime_type: "Image/AVIF", filename: "image-4.avif"}
             ]
           }
  end

  test "chat string scans exact data URL matches and camel inline data keeps contiguous filenames",
       ctx do
    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/scan/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "model" => "Vendor/Image",
               "messages" => [%{"role" => "user", "content" => " A mountain 雪\n"}],
               "modalities" => ["image", "text"],
               "n" => 1
             }

      json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => "first data:image/png;base64,b25l then data:image/jpeg;base64,dHdv"
            }
          },
          %{
            "message" => %{
              "content" => [
                %{"inlineData" => %{"data" => "dGhyZWU=", "mimeType" => " image/webp "}},
                %{"inlineData" => %{"data" => "Zm91cg=="}}
              ]
            }
          }
        ]
      })
    end)

    req = Map.merge(request(), %{model: " Vendor/Image ", aspect_ratio: "16:9", resolution: "4K"})
    assert {:ok, result} = generate(ctx.tasks, req, config(Gaoxy.Test.url(ctx.fixture, "/scan")))

    assert result == %{
             model: "Vendor/Image",
             images: [
               %{data: "one", mime_type: "image/png", filename: "image-1.png"},
               %{data: "two", mime_type: "image/jpeg", filename: "image-2.jpg"},
               %{data: "three", mime_type: "image/webp", filename: "image-3.webp"},
               %{data: "four", mime_type: "image/png", filename: "image-4.png"}
             ]
           }
  end

  test "four dedicated requests reach a barrier together and reverse completion retains request order",
       ctx do
    test_pid = self()

    responses = [
      %{"b64_json" => "/9j/AA==", "revised_prompt" => " revised snow "},
      %{"b64_json" => "UklGRjEyMzRXRUJQcGF5bG9hZA==", "media_type" => " Image/AVIF "},
      %{
        "b64_json" => "iVBORw0KGgo=",
        "mime_type" => "image/svg+xml",
        "media_type" => "image/jpeg"
      },
      %{"b64_json" => "b3BhcXVl"}
    ]

    fixtures =
      for index <- 0..3, into: %{} do
        fixture = Gaoxy.Test.open()
        on_exit(fn -> Gaoxy.Test.close(fixture) end)
        {index, fixture}
      end

    route_requests(fixtures)

    for {entry, index} <- Enum.with_index(responses) do
      Gaoxy.Test.expect_once(fixtures[index], "POST", "/api/v1/images", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "model" => "google/gemini-test",
                 "prompt" => " A mountain 雪\n",
                 "n" => 1
               }

        send(test_pid, {:arrived, index, self()})

        receive do
          :respond -> :ok
        after
          3_000 -> flunk("four ordinary requests did not reach their barrier")
        end

        json(conn, %{"data" => [entry]})
      end)
    end

    caller =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        OpenRouter.generate(Map.put(request(), :count, 4), config("https://openrouter.ai/api/v1"))
      end)

    handlers =
      for _ <- 1..4 do
        assert_receive {:arrived, index, handler}, 2_000
        {index, handler}
      end

    {:links, links} = Process.info(caller.pid, :links)
    assert [owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != ctx.tasks end)
    ref = Process.monitor(owner)
    {:links, owner_links} = Process.info(owner, :links)
    children = Enum.filter(owner_links, &(&1 != caller.pid))
    assert length(children) == 4

    for {index, handler} <- Enum.sort(handlers, :desc) do
      send(handler, :respond)
      assert_receive {:request_completed, ^index}, 2_000
    end

    assert Task.await(caller, 5_000) ==
             {:ok,
              %{
                model: "google/gemini-test",
                images: [
                  %{
                    data: <<255, 216, 255, 0>>,
                    mime_type: "image/jpeg",
                    filename: "image-1.jpg",
                    revised_prompt: "revised snow"
                  },
                  %{
                    data: "RIFF1234WEBPpayload",
                    mime_type: "Image/AVIF",
                    filename: "image-1.avif"
                  },
                  %{
                    data: <<137, 80, 78, 71, 13, 10, 26, 10>>,
                    mime_type: "image/svg+xml",
                    filename: "image-1.svg"
                  },
                  %{data: "opaque", mime_type: "image/png", filename: "image-1.png"}
                ]
              }}

    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
    assert Enum.all?(children, &(not Process.alive?(&1)))
  end

  test "all 39 comparable fixed-source rows match full plans, actual HTTP and ordered results",
       ctx do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @ids

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-default-model-timeout",
             "source-only-configured-header"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 39

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = OpenRouter.build_request(req, cfg)
      assert built.request_count == length(row["requests"]), id
      assert built.request_count == length(row["responses"]), id
      assert built.model == row["result"]["model"], id

      assert built.mode ==
               if(String.ends_with?(built.url, "/images"), do: :dedicated, else: :chat),
             id

      assert built.max_image_bytes == Map.get(cfg, :max_image_bytes, 64 * 1024 * 1024), id
      assert row["inputAfter"] == row["input"], id

      assert row["completionOrder"] == if(built.request_count == 4, do: [3, 2, 1, 0], else: [0]),
             id

      for {expected, index} <- Enum.with_index(row["requests"]) do
        assert expected["ordinal"] == index, id
        assert expected["method"] == "POST", id
        assert expected["releaseCount"] == 1, id
        assert Jason.decode!(expected["rawBody"]) == expected["body"], id

        assert Map.take(expected, ["url", "body", "headers", "timeoutMs", "maxBytes"]) == %{
                 "url" => built.url,
                 "body" => built.body,
                 "headers" => built.headers,
                 "timeoutMs" => built.timeout_ms,
                 "maxBytes" => built.max_response_bytes
               },
               id
      end

      fixtures =
        for expected <- row["requests"], into: %{} do
          fixture = Gaoxy.Test.open()
          on_exit(fn -> Gaoxy.Test.close(fixture) end)
          {expected["ordinal"], fixture}
        end

      restore = route_requests(fixtures, row["requests"])
      test_pid = self()

      try do
        for {expected, response} <- Enum.zip(row["requests"], row["responses"]) do
          index = expected["ordinal"]
          path = URI.parse(expected["url"]).path

          Gaoxy.Test.expect_once(fixtures[index], "POST", path, fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(raw) == expected["body"], id

            for {name, value} <- expected["wireHeaders"] do
              assert Plug.Conn.get_req_header(conn, name) == [value], id
            end

            send(test_pid, {:oracle_arrived, id, index, self()})

            receive do
              :respond -> :ok
            after
              3_000 -> flunk("ordinary reference response was not released: #{id}")
            end

            json(conn, response["json"])
          end)
        end

        caller = Task.Supervisor.async_nolink(ctx.tasks, fn -> OpenRouter.generate(req, cfg) end)

        handlers =
          for _ <- row["requests"], into: %{} do
            assert_receive {:oracle_arrived, ^id, index, handler}, 2_000
            {index, handler}
          end

        assert Enum.sort(Map.keys(handlers)) == Enum.to_list(0..(built.request_count - 1)), id

        for index <- row["completionOrder"] do
          send(Map.fetch!(handlers, index), :respond)
          assert_receive {:request_completed, ^index}, 2_000
        end

        assert Task.await(caller, 5_000) == {:ok, reference_result(row["result"])}, id

        assert Enum.map(row["releaseCalls"], &Map.take(&1, ["ordinal", "releaseCount"])) ==
                 Enum.map(row["completionOrder"], &%{"ordinal" => &1, "releaseCount" => 1}),
               id

        Enum.each(fixtures, fn {_index, fixture} -> Gaoxy.Test.verify_and_close!(fixture) end)
      after
        restore.()
      end
    end
  end

  defp reference_request(input) do
    keys = %{
      "prompt" => :prompt,
      "model" => :model,
      "timeoutMs" => :timeout_ms,
      "count" => :count,
      "size" => :size,
      "quality" => :quality,
      "outputFormat" => :output_format,
      "background" => :background,
      "aspectRatio" => :aspect_ratio,
      "resolution" => :resolution,
      "providerOptions" => :provider_options
    }

    req =
      for {source, target} <- keys,
          Map.has_key?(input, source),
          into: %{},
          do: {target, input[source]}

    if images = input["inputImages"] do
      Map.put(
        req,
        :input_images,
        Enum.map(images, fn image ->
          %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"]
          }
        end)
      )
    else
      req
    end
  end

  defp reference_config(input) do
    cfg = config(input["baseUrl"])

    if megabytes = input["mediaMaxMb"],
      do: Map.put(cfg, :max_image_bytes, max(64 * 1024 * 1024, floor(megabytes * 1024 * 1024))),
      else: cfg
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

          if prompt = image["revisedPrompt"],
            do: Map.put(asset, :revised_prompt, prompt),
            else: asset
        end)
    }
  end

  defp route_requests(fixtures, expected_requests \\ nil) do
    previous = Req.default_options()
    test_pid = self()
    on_exit(fn -> Req.default_options(previous) end)

    redirect = fn request ->
      Req.Request.prepend_request_steps(request,
        openrouter_fixture: fn request ->
          index = Req.Request.get_private(request, :openrouter_image_request_index)

          expected_url =
            if expected_requests,
              do: Enum.fetch!(expected_requests, index)["url"],
              else: "https://openrouter.ai/api/v1/images"

          assert URI.to_string(request.url) == expected_url
          assert request.method == :post
          address = URI.parse(Gaoxy.Test.url(Map.fetch!(fixtures, index)))

          request = %{
            request
            | url: %{
                request.url
                | scheme: address.scheme,
                  host: address.host,
                  port: address.port
              }
          }

          Req.Request.append_response_steps(request,
            completion: fn {request, response} ->
              send(test_pid, {:request_completed, index})
              {request, response}
            end
          )
        end
      )
    end

    Req.default_options(
      Keyword.put(previous, :plugins, [redirect | Keyword.get(previous, :plugins, [])])
    )

    fn -> Req.default_options(previous) end
  end

  defp request,
    do: %{prompt: " A mountain 雪\n", model: "\uFEFF google/gemini-test \u00A0", timeout_ms: 5_000}

  defp config(base), do: %{api_key: "synthetic-explicit-key", base_url: base}

  defp json(conn, payload),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))

  defp generate(tasks, req, cfg),
    do:
      tasks
      |> Task.Supervisor.async_nolink(fn -> OpenRouter.generate(req, cfg) end)
      |> Task.await(7_000)
end
