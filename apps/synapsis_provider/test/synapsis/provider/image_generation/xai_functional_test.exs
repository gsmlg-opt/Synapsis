defmodule Synapsis.Provider.ImageGeneration.XAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.XAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/xai-image-generation.json",
               __DIR__
             )
  @ids ~w(default-count explicit-model-prompt count-four count-seven-clamped aspect-1-1 aspect-16-9 aspect-9-16 aspect-4-3 aspect-3-4 aspect-3-2 aspect-2-3 aspect-2-1 aspect-1-2 aspect-19.5-9 aspect-9-19.5 aspect-20-9 aspect-9-20 unsupported-aspect-omitted resolution-1k resolution-2k resolution-custom unused-options edit-url edit-bytes-default-mime edit-bytes-explicit-mime edit-url-preferred edit-three-ordered custom-base javascript-whitespace ordered-inline-mime-prompts base64-unpadded base64-whitespace jpeg-default-png-no-sniff opaque-default-png six-inline-preserved four-ordered-downloads mixed-inline-downloads inline-preferred-over-url media-cap-floor media-cap-larger source-only-default-model-timeout)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "generation keeps an explicit trimmed model and source aspect and resolution controls" do
    req =
      Map.merge(request(), %{
        model: "\uFEFF Custom/IMAGE-v2 \u00A0",
        count: 7,
        aspect_ratio: " 19.5:9 ",
        resolution: "\uFEFF 2K \u00A0",
        size: "1536x1024",
        quality: "high",
        output_format: "webp",
        background: "transparent",
        provider_options: %{xai: %{unused: true}}
      })

    assert {:ok, built} = XAI.build_request(req, config("https://images.example/custom/v1///"))
    assert built.url == "https://images.example/custom/v1/images/generations"
    assert built.model == "Custom/IMAGE-v2"
    assert built.timeout_ms == 5_000
    assert built.max_image_bytes == 64 * 1024 * 1024
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024

    assert built.body == %{
             "model" => "Custom/IMAGE-v2",
             "prompt" => " A mountain 雪\n",
             "n" => 4,
             "response_format" => "b64_json",
             "aspect_ratio" => "19.5:9",
             "resolution" => "2k"
           }
  end

  test "one edit uses image while three ordered edits prefer URL and retain exact data bytes" do
    remote = %{url: "\uFEFF https://assets.example/input.png \u00A0", data: "unused"}
    first = %{"url" => "https://assets.example/input.png", "type" => "image_url"}

    assert {:ok, single} =
             XAI.build_request(
               Map.put(request(), :input_images, [remote]),
               config("https://images.example/v1")
             )

    assert single.url == "https://images.example/v1/images/edits"
    assert single.body == Map.put(body(), "image", first)

    assert {:ok, multiple} =
             XAI.build_request(
               Map.put(request(), :input_images, [
                 remote,
                 %{data: <<0, 255, 1>>, mime_type: " Image/WebP; source=raw "},
                 %{data: "third", mime_type: " "}
               ]),
               config("https://images.example/v1/")
             )

    assert multiple.body ==
             Map.put(body(), "images", [
               first,
               %{
                 "url" => "data:Image/WebP; source=raw;base64,AP8B",
                 "type" => "image_url"
               },
               %{"url" => "data:image/png;base64,dGhpcmQ=", "type" => "image_url"}
             ])
  end

  test "actual generation returns every ordered inline asset with MIME and revised prompt", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<255, 216, 255, 0>>

    response = %{
      "data" => [
        %{"b64_json" => Base.encode64(bytes), "revised_prompt" => "\uFEFF Snow 雪 \u00A0"},
        %{"b64_json" => Base.encode64("two"), "mime_type" => " Image/JPEG; custom=raw "},
        %{"b64_json" => Base.encode64("three"), "mime_type" => "image/svg+xml"},
        %{"b64_json" => Base.encode64("four"), "mime_type" => "image/webp"},
        %{"b64_json" => Base.encode64("five"), "mime_type" => "image/gif"}
      ],
      "usage" => %{"total_tokens" => 42},
      "metadata" => %{"ignored" => true}
    }

    expect_json(fixture, "/v1/images/generations", body(), response)
    assert {:ok, result} = generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/v1")))

    assert result == %{
             model: "grok-imagine-image",
             images: [
               %{
                 data: bytes,
                 mime_type: "image/png",
                 filename: "image-1.png",
                 revised_prompt: "Snow 雪"
               },
               %{data: "two", mime_type: "Image/JPEG; custom=raw", filename: "image-2.jpg"},
               %{data: "three", mime_type: "image/svg+xml", filename: "image-3.svg"},
               %{data: "four", mime_type: "image/webp", filename: "image-4.webp"},
               %{data: "five", mime_type: "image/gif", filename: "image-5.gif"}
             ]
           }
  end

  test "actual JSON edit downloads four ordinary URL assets sequentially in response order", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    for index <- 1..4 do
      Gaoxy.Test.expect_once(fixture, "GET", "/assets/#{index}", fn conn ->
        send(owner, {:download, index})

        conn
        |> Plug.Conn.put_resp_header("content-type", "Image/WebP; source=download")
        |> Plug.Conn.resp(200, "download-#{index}")
      end)
    end

    req = Map.put(request(), :input_images, [%{data: "source"}])

    expected =
      Map.put(body(), "image", %{"url" => "data:image/png;base64,c291cmNl", "type" => "image_url"})

    response = %{
      "data" =>
        for(
          index <- 1..4,
          do: %{
            "url" => " " <> Gaoxy.Test.url(fixture, "/assets/#{index}") <> " ",
            "revised_prompt" => " image #{index} "
          }
        )
    }

    expect_json(fixture, "/v1/images/edits", expected, response)
    assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, "/v1")))

    assert result == %{
             model: "grok-imagine-image",
             images:
               for(
                 index <- 1..4,
                 do: %{
                   data: "download-#{index}",
                   mime_type: "image/webp",
                   filename: "image-#{index}.webp",
                   revised_prompt: "image #{index}"
                 }
               )
           }

    downloads =
      for _ <- 1..4 do
        assert_receive {:download, index}
        index
      end

    assert downloads == [1, 2, 3, 4]
  end

  test "all thirteen aspects and arbitrary nonblank resolutions follow the source callback" do
    for aspect <- ~w(1:1 16:9 9:16 4:3 3:4 3:2 2:3 2:1 1:2 19.5:9 9:19.5 20:9 9:20) do
      assert {:ok, built} =
               XAI.build_request(
                 Map.merge(request(), %{aspect_ratio: "\uFEFF" <> aspect <> "\u2029", count: 4}),
                 config("https://api.x.ai/v1")
               )

      assert built.body == Map.merge(body(), %{"aspect_ratio" => aspect, "n" => 4})
    end

    for {aspect, resolution, extra} <- [
          {"21:9", " 4K ", %{"resolution" => "4k"}},
          {"", "\uFEFF \u00A0", %{}},
          {"16:9", " Custom-Tier ", %{"aspect_ratio" => "16:9", "resolution" => "custom-tier"}}
        ] do
      assert {:ok, built} =
               XAI.build_request(
                 Map.merge(request(), %{aspect_ratio: aspect, resolution: resolution}),
                 config("https://images.example/v1")
               )

      assert built.body == Map.merge(body(), extra)
    end

    for count <- [1, 4, 9], bound <- [17, 96 * 1024 * 1024] do
      assert {:ok, built} =
               XAI.build_request(
                 Map.put(request(), :count, count),
                 Map.put(config("https://images.example/v1"), :max_image_bytes, bound)
               )

      assert built.body["n"] == min(count, 4)
      assert built.max_image_bytes == bound

      assert built.max_response_bytes ==
               div(max(64 * 1024 * 1024, bound) * 4 * 4 + 2, 3) + 1024 * 1024
    end
  end

  test "actual three-image JSON edit preserves URL-only inputs and ordered MIME data URLs", %{
    fixture: fixture,
    tasks: tasks
  } do
    req =
      Map.put(request(), :input_images, [
        %{url: " https://assets.example/url-only.webp "},
        %{url: " ", data: <<0, 255, 128>>, mime_type: "\uFEFF Image/JPG \u00A0"},
        %{data: "third", filename: "ignored.svg"}
      ])

    expected =
      Map.put(body(), "images", [
        %{"url" => "https://assets.example/url-only.webp", "type" => "image_url"},
        %{"url" => "data:Image/JPG;base64,AP+A", "type" => "image_url"},
        %{"url" => "data:image/png;base64,dGhpcmQ=", "type" => "image_url"}
      ])

    response = %{"data" => [%{"b64_json" => Base.encode64("edited")}]}
    expect_json(fixture, "/three/v1/images/edits", expected, response)

    assert {:ok, result} =
             generate(tasks, req, config(Gaoxy.Test.url(fixture, "/three/v1")))

    assert result == %{
             model: "grok-imagine-image",
             images: [%{data: "edited", mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "ordinary canonical padded, unpadded and ASCII-whitespace inline encodings retain bytes",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    response = %{
      "data" => [
        %{"b64_json" => "\uFEFF +/8= \u00A0", "mime_type" => "image/jpg"},
        %{"b64_json" => "+/8", "mime_type" => " image/avif "},
        %{"b64_json" => " Y\nW\tJ\rj ", "mime_type" => "image/vnd.custom+xml"},
        %{"b64_json" => Base.encode64("last"), "mime_type" => "\uFEFF ", "revised_prompt" => " "}
      ]
    }

    expect_json(fixture, "/encoding/images/generations", body(), response)

    assert {:ok, result} =
             generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/encoding")))

    assert result.images == [
             %{data: <<251, 255>>, mime_type: "image/jpg", filename: "image-1.jpg"},
             %{data: <<251, 255>>, mime_type: "image/avif", filename: "image-2.avif"},
             %{
               data: "abc",
               mime_type: "image/vnd.custom+xml",
               filename: "image-3.vnd.custom+xml"
             },
             %{data: "last", mime_type: "image/png", filename: "image-4.png"}
           ]
  end

  test "successful chunked JSON and decoded image reach their exact explicit positive bounds", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = :binary.copy(<<0, 255, 128>>, 65_537)

    response =
      Jason.encode!(%{
        "data" => [%{"b64_json" => Base.encode64(bytes), "mime_type" => "image/webp"}]
      })

    Gaoxy.Test.expect_once(fixture, "POST", "/bounded/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body()

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(chunks(response, 997), conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    cfg =
      Map.merge(config(Gaoxy.Test.url(fixture, "/bounded")), %{
        max_image_bytes: byte_size(bytes),
        max_response_bytes: byte_size(response)
      })

    assert {:ok, result} = generate(tasks, request(), cfg)

    assert result == %{
             model: "grok-imagine-image",
             images: [%{data: bytes, mime_type: "image/webp", filename: "image-1.webp"}]
           }
  end

  test "successful linked HTTP owner exits normally after its one POST", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/owner/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body()
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
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("normal")}]})
      )
    end)

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        XAI.generate(request(), config(Gaoxy.Test.url(fixture, "/owner")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)
    assert result.images == [%{data: "normal", mime_type: "image/png", filename: "image-1.png"}]
    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all explicit fixed-source rows match complete plans and actual ordered local HTTP", %{
    fixture: fixture,
    tasks: tasks
  } do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @ids
    source_only = Enum.filter(rows, &(not &1["hostComparable"]))
    assert Enum.map(source_only, & &1["id"]) == ["source-only-default-model-timeout"]
    assert hd(source_only)["request"]["timeoutMs"] == 600_000
    assert hd(source_only)["result"]["model"] == "grok-imagine-image"
    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 40

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = XAI.build_request(req, cfg)
      assert built.url == row["request"]["url"], id
      assert built.body == row["request"]["body"], id
      assert built.body == row["request"]["jsonBody"], id
      assert built.timeout_ms == row["request"]["timeoutMs"], id
      assert built.max_response_bytes == row["request"]["maxBytes"], id
      assert built.model == row["result"]["model"], id
      assert row["request"]["method"] == "POST", id
      assert row["releaseCount"] == 1, id
      assert row["inputAfter"] == row["input"], id

      prefix = "/reference/" <> id
      local_response = reference_downloads(fixture, prefix, row)

      action =
        if Map.has_key?(built.body, "image") or Map.has_key?(built.body, "images"),
          do: "edits",
          else: "generations"

      expect_json(fixture, prefix <> "/images/" <> action, row["request"]["body"], local_response)

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"]), id

      observed_downloads =
        for _download <- row["downloads"] do
          assert_receive {:reference_download, observed_id, url}
          assert observed_id == id
          url
        end

      assert observed_downloads == Enum.map(row["downloads"], & &1["url"]), id
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
          fields = %{mime_type: image["mimeType"], filename: image["fileName"], url: image["url"]}

          if Map.has_key?(image, "bytesBase64"),
            do: Map.put(fields, :data, Base.decode64!(image["bytesBase64"])),
            else: fields
        end)
      )
    else
      req
    end
  end

  defp reference_config(input) do
    cfg = config(input["baseUrl"])

    if input["mediaMaxMb"],
      do:
        Map.put(
          cfg,
          :max_image_bytes,
          max(64 * 1024 * 1024, trunc(input["mediaMaxMb"] * 1024 * 1024))
        ),
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

          if Map.has_key?(image, "revisedPrompt"),
            do: Map.put(asset, :revised_prompt, image["revisedPrompt"]),
            else: asset
        end)
    }
  end

  defp reference_downloads(fixture, prefix, row) do
    test_pid = self()

    local_urls =
      row["downloads"]
      |> Enum.with_index(1)
      |> Map.new(fn {download, index} ->
        assert download["method"] == "GET"
        assert download["releaseCount"] == 1
        path = prefix <> "/assets/#{index}"

        Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
          send(test_pid, {:reference_download, row["id"], download["url"]})

          conn
          |> Plug.Conn.put_resp_header("content-type", download["contentType"])
          |> Plug.Conn.resp(200, Base.decode64!(download["bodyBase64"]))
        end)

        {download["url"], Gaoxy.Test.url(fixture, path)}
      end)

    Map.update!(row["response"]["json"], "data", fn entries ->
      Enum.map(entries, fn entry ->
        case local_urls[String.trim(entry["url"] || "")] do
          nil -> entry
          local_url -> Map.put(entry, "url", local_url)
        end
      end)
    end)
  end

  defp chunks("", _size), do: []

  defp chunks(body, size) when byte_size(body) <= size, do: [body]

  defp chunks(body, size) do
    <<chunk::binary-size(size), rest::binary>> = body
    [chunk | chunks(rest, size)]
  end

  defp request,
    do: %{prompt: " A mountain 雪\n", model: "grok-imagine-image", timeout_ms: 5_000}

  defp config(base_url), do: %{api_key: "xai-image-fixture", base_url: base_url}

  defp body,
    do: %{
      "model" => "grok-imagine-image",
      "prompt" => " A mountain 雪\n",
      "n" => 1,
      "response_format" => "b64_json"
    }

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> XAI.generate(request, config) end)
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
