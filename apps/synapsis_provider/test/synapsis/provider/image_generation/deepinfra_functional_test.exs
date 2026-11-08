defmodule Synapsis.Provider.ImageGeneration.DeepInfraFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.DeepInfra

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/deepinfra-image-generation.json",
               __DIR__
             )
  @ids ~w(default-count-size explicit-model-prompt deepinfra-prefixed-model count-four size-512 size-1024 size-portrait size-landscape size-trim unused-options edit-defaults edit-explicit-size-count edit-explicit-mime-filename edit-unicode-path-name edit-default-jpeg-filename custom-base javascript-whitespace ordered-inline-sniff-prompts explicit-mime-wins base64-unpadded base64-whitespace four-ordered-downloads edit-one-download json-bom-raw-chunks media-cap-floor media-cap-larger source-only-default-model-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "generation defaults retain prompt and strip only the exact model prefix" do
    assert {:ok, built} =
             DeepInfra.build_request(
               request(),
               config("\uFEFF https://api.deepinfra.com/v1/openai/// \u00A0")
             )

    assert built.url == "https://api.deepinfra.com/v1/openai/images/generations"
    assert built.model == "black-forest-labs/FLUX-1-schnell"
    assert built.timeout_ms == 5_000
    assert built.body == body()
    assert built.max_image_bytes == 64 * 1024 * 1024
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024

    for {model, expected} <- [
          {" DeepInfra/Custom ", "DeepInfra/Custom"},
          {"\uFEFF deepinfra/Qwen/Qwen-Image-Max \u2029", "Qwen/Qwen-Image-Max"},
          {" other/model ", "other/model"}
        ] do
      assert {:ok, built} =
               DeepInfra.build_request(
                 Map.merge(request(), %{model: model, size: " 2000x1125 ", count: 3}),
                 config("https://images.example/custom/")
               )

      assert built.url == "https://images.example/custom/images/generations"

      assert built.body ==
               Map.merge(body(), %{"model" => expected, "size" => "2000x1125", "n" => 3})
    end
  end

  test "real JSON generation retains all inline images, sniffing only absent MIME", %{
    fixture: fixture,
    tasks: tasks
  } do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 1>>
    jpeg = <<255, 216, 255, 0>>
    webp = "RIFF1234WEBPpayload"

    response = %{
      "data" => [
        %{"b64_json" => Base.encode64(jpeg), "revised_prompt" => " revised snow \n"},
        %{"b64_json" => Base.encode64(png)},
        %{"b64_json" => Base.encode64(webp)},
        %{"b64_json" => Base.encode64("opaque")},
        %{"b64_json" => Base.encode64(png), "mime_type" => " Image/SVG+XML ; profile=one "}
      ],
      "usage" => %{"total_tokens" => 9}
    }

    expect_json(fixture, "/generation/images/generations", body(), response)

    assert {:ok, result} =
             generate(tasks, request(), config(Gaoxy.Test.url(fixture, "/generation")))

    assert result == %{
             model: "black-forest-labs/FLUX-1-schnell",
             images: [
               %{
                 data: jpeg,
                 mime_type: "image/jpeg",
                 filename: "image-1.jpg",
                 revised_prompt: "revised snow"
               },
               %{data: png, mime_type: "image/png", filename: "image-2.png"},
               %{data: webp, mime_type: "image/webp", filename: "image-3.webp"},
               %{data: "opaque", mime_type: "image/jpeg", filename: "image-4.jpg"},
               %{data: png, mime_type: "Image/SVG+XML ; profile=one", filename: "image-5.svg"}
             ]
           }
  end

  test "one reference image uses ordered singular multipart fields and count one", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<0, 255, 128, 13, 10, 1>>

    req =
      Map.merge(request(), %{
        count: 3,
        size: " \uFEFF1024x1792\u00A0 ",
        input_images: [%{data: bytes, mime_type: " Image/JPEG ", filename: " /photos/snow.jpg "}],
        quality: "high",
        output_format: "webp",
        aspect_ratio: "16:9",
        resolution: "4K",
        background: "transparent",
        provider_options: %{deepinfra: %{unused: true}}
      })

    assert {:ok, built} = DeepInfra.build_request(req, config("https://images.example/api///"))
    assert built.url == "https://images.example/api/images/edits"
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 4 + 2, 3) + 1024 * 1024

    assert built.form == [
             {"model", "black-forest-labs/FLUX-1-schnell"},
             {"prompt", " A mountain 雪\n"},
             {"n", "1"},
             {"size", "1024x1792"},
             {"response_format", "b64_json"},
             {"image", {bytes, filename: "/photos/snow.jpg", content_type: "image/jpeg"}}
           ]

    Gaoxy.Test.expect_once(fixture, "POST", "/edit/images/edits", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)

      assert multipart_parts(raw, boundary) == [
               %{name: "model", value: "black-forest-labs/FLUX-1-schnell"},
               %{name: "prompt", value: " A mountain 雪\n"},
               %{name: "n", value: "1"},
               %{name: "size", value: "1024x1792"},
               %{name: "response_format", value: "b64_json"},
               %{
                 name: "image",
                 value: bytes,
                 filename: "/photos/snow.jpg",
                 mime_type: "image/jpeg"
               }
             ]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("edited")}]})
      )
    end)

    assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, "/edit")))
    assert result.images == [%{data: "edited", mime_type: "image/jpeg", filename: "image-1.jpg"}]
  end

  test "reference upload defaults use PNG and the source MIME extension", %{
    fixture: fixture,
    tasks: tasks
  } do
    for {image, filename, mime} <- [
          {%{data: "default"}, "image-1.png", "image/png"},
          {%{data: "custom", mime_type: " image/vnd.custom+xml "}, "image-1.vnd.custom+xml",
           "image/vnd.custom+xml"}
        ] do
      req = Map.merge(request(), %{input_images: [image], size: " \uFEFF "})
      assert {:ok, built} = DeepInfra.build_request(req, config("https://images.example"))

      assert built.form == [
               {"model", "black-forest-labs/FLUX-1-schnell"},
               {"prompt", " A mountain 雪\n"},
               {"n", "1"},
               {"size", "1024x1024"},
               {"response_format", "b64_json"},
               {"image", {image.data, filename: filename, content_type: mime}}
             ]

      path = "/defaults/" <> URI.encode(filename) <> "/images/edits"

      Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("ok")}]}))
      end)

      assert {:ok, %{images: [%{data: "ok", mime_type: "image/jpeg", filename: "image-1.jpg"}]}} =
               generate(
                 tasks,
                 req,
                 config(Gaoxy.Test.url(fixture, "/defaults/" <> URI.encode(filename)))
               )
    end
  end

  test "ordinary configured headers trim values and JSON controls its content type", %{
    fixture: fixture,
    tasks: tasks
  } do
    cfg =
      Map.put(config(Gaoxy.Test.url(fixture, "/headers")), :request, %{
        headers: %{"X-Image-Profile" => " \uFEFFstudio \u00A0", "Content-Type" => "text/plain"}
      })

    assert {:ok, built} = DeepInfra.build_request(request(), cfg)
    assert built.headers["x-image-profile"] == "studio"
    assert built.headers["content-type"] == "application/json"

    Gaoxy.Test.expect_once(fixture, "POST", "/headers/images/generations", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body()

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("ordinary")}]})
      )
    end)

    assert {:ok,
            %{images: [%{data: "ordinary", mime_type: "image/jpeg", filename: "image-1.jpg"}]}} =
             generate(tasks, request(), cfg)
  end

  test "multipart generates its boundary after ordinary configured content type", %{
    fixture: fixture,
    tasks: tasks
  } do
    req = Map.put(request(), :input_images, [%{data: "reference"}])

    cfg =
      Map.put(config(Gaoxy.Test.url(fixture, "/multipart-headers")), :request, %{
        headers: %{"X-Image-Profile" => " studio ", "content-type" => "text/plain"}
      })

    assert {:ok, built} = DeepInfra.build_request(req, cfg)
    assert built.headers["x-image-profile"] == "studio"
    refute Map.has_key?(built.headers, "content-type")

    Gaoxy.Test.expect_once(fixture, "POST", "/multipart-headers/images/edits", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert multipart_parts(raw, boundary) == [
               %{name: "model", value: "black-forest-labs/FLUX-1-schnell"},
               %{name: "prompt", value: " A mountain 雪\n"},
               %{name: "n", value: "1"},
               %{name: "size", value: "1024x1024"},
               %{name: "response_format", value: "b64_json"},
               %{
                 name: "image",
                 value: "reference",
                 filename: "image-1.png",
                 mime_type: "image/png"
               }
             ]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("ordinary")}]})
      )
    end)

    assert {:ok,
            %{images: [%{data: "ordinary", mime_type: "image/jpeg", filename: "image-1.jpg"}]}} =
             generate(tasks, req, cfg)
  end

  test "ordinary URL downloads remain ordered and retain transport MIME", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    sources = [
      {"one", "Image/WebP; profile=one", "image/webp", "webp"},
      {"two", "image/jpeg", "image/jpeg", "jpg"},
      {"three", "image/png; charset=binary", "image/png", "png"},
      {"four", "image/avif", "image/avif", "avif"}
    ]

    entries =
      Enum.with_index(sources, 1)
      |> Enum.map(fn {{bytes, content_type, _mime, _ext}, index} ->
        path = "/ordered/assets/#{index}"

        Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
          send(test_pid, {:download, index})

          conn
          |> Plug.Conn.put_resp_header("content-type", content_type)
          |> Plug.Conn.resp(200, bytes)
        end)

        %{"url" => Gaoxy.Test.url(fixture, path), "revised_prompt" => " image #{index} "}
      end)

    expect_json(fixture, "/ordered/images/generations", Map.put(body(), "n", 4), %{
      "data" => entries
    })

    assert {:ok, result} =
             generate(
               tasks,
               Map.put(request(), :count, 4),
               config(Gaoxy.Test.url(fixture, "/ordered"))
             )

    assert result == %{
             model: "black-forest-labs/FLUX-1-schnell",
             images:
               Enum.with_index(sources, 1)
               |> Enum.map(fn {{bytes, _type, mime, ext}, index} ->
                 %{
                   data: bytes,
                   mime_type: mime,
                   filename: "image-#{index}.#{ext}",
                   revised_prompt: "image #{index}"
                 }
               end)
           }

    assert_receive {:download, 1}
    assert_receive {:download, 2}
    assert_receive {:download, 3}
    assert_receive {:download, 4}
  end

  test "successful chunked JSON and image bytes meet explicit exact bounds", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = :binary.copy(<<0, 255, 128>>, 257)
    raw = Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(bytes)}]})

    Gaoxy.Test.expect_once(fixture, "POST", "/bounded/images/generations", fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(request_body) == body()

      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      <<first::binary-size(19), rest::binary>> = raw
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)

    cfg =
      Map.merge(config(Gaoxy.Test.url(fixture, "/bounded")), %{
        max_image_bytes: byte_size(bytes),
        max_response_bytes: byte_size(raw)
      })

    assert {:ok, result} = generate(tasks, request(), cfg)

    assert result == %{
             model: "black-forest-labs/FLUX-1-schnell",
             images: [%{data: bytes, mime_type: "image/jpeg", filename: "image-1.jpg"}]
           }
  end

  test "successful linked HTTP owner exits normally after one operation", %{
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
        DeepInfra.generate(request(), config(Gaoxy.Test.url(fixture, "/owner")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)
    assert result.images == [%{data: "normal", mime_type: "image/jpeg", filename: "image-1.jpg"}]
    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all comparable fixed-source rows match full plans, actual ordered HTTP and results", %{
    fixture: fixture,
    tasks: tasks
  } do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @ids

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-default-model-timeout",
             "source-only-configured-header"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert Enum.count(comparable) == 26

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = DeepInfra.build_request(req, cfg)

      assert reference_plan(built) ==
               Map.take(row["request"], [
                 "url",
                 "method",
                 "kind",
                 "body",
                 "jsonBody",
                 "headers",
                 "timeoutMs",
                 "maxBytes"
               ]),
             id

      assert built.model == row["result"]["model"], id
      assert row["releaseCount"] == 1, id
      assert row["request"]["releaseCount"] == 1, id
      assert row["inputAfter"] == row["input"], id

      prefix = "/reference/" <> id
      local_response = reference_downloads(fixture, prefix, row)
      action = if row["request"]["kind"] == "multipart", do: "edits", else: "generations"

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/images/" <> action, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        for {name, value} <- row["request"]["headers"] do
          assert Plug.Conn.get_req_header(conn, name) == [value], id
        end

        case row["request"]["kind"] do
          "json" ->
            assert Jason.decode!(raw) == row["request"]["body"], id

          "multipart" ->
            [content_type] = Plug.Conn.get_req_header(conn, "content-type")
            [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)

            assert Enum.map(multipart_parts(raw, boundary), &reference_wire_part/1) ==
                     row["request"]["body"],
                   id
        end

        case row["response"]["rawChunks"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(local_response))

          raw_chunks ->
            conn =
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_chunked(200)

            Enum.reduce(raw_chunks, conn, fn chunk, conn ->
              {:ok, conn} = Plug.Conn.chunk(conn, Base.decode64!(chunk))
              conn
            end)
        end
      end)

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"]), id

      observed_downloads =
        for _download <- row["downloads"] do
          assert_receive {:reference_download, observed_id, source_url}
          assert observed_id == id
          source_url
        end

      assert observed_downloads == Enum.map(row["downloads"], & &1["url"]), id
    end
  end

  defp reference_request(input) do
    req = %{prompt: input["prompt"], model: input["model"], timeout_ms: input["timeoutMs"]}

    req =
      Enum.reduce(
        [
          {"count", :count},
          {"size", :size},
          {"quality", :quality},
          {"outputFormat", :output_format},
          {"background", :background},
          {"aspectRatio", :aspect_ratio},
          {"resolution", :resolution},
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
            filename: image["fileName"]
          }
        end)
      )
    else
      req
    end
  end

  defp reference_config(input) do
    cfg = %{api_key: "synthetic-explicit-key", base_url: input["baseUrl"]}

    if input["mediaMaxMb"],
      do:
        Map.put(
          cfg,
          :max_image_bytes,
          max(64 * 1024 * 1024, trunc(input["mediaMaxMb"] * 1024 * 1024))
        ),
      else: cfg
  end

  defp reference_plan(built) do
    plan = %{
      "url" => built.url,
      "method" => "POST",
      "headers" => built.headers,
      "timeoutMs" => built.timeout_ms,
      "maxBytes" => built.max_response_bytes
    }

    case built do
      %{body: body} ->
        Map.merge(plan, %{"kind" => "json", "body" => body, "jsonBody" => body})

      %{form: form} ->
        Map.merge(plan, %{"kind" => "multipart", "body" => Enum.map(form, &reference_form_part/1)})
    end
  end

  defp reference_form_part({name, {bytes, options}}) do
    %{
      "name" => name,
      "fileName" => options[:filename],
      "mimeType" => options[:content_type],
      "size" => byte_size(bytes),
      "bytesBase64" => Base.encode64(bytes)
    }
  end

  defp reference_form_part({name, value}), do: %{"name" => name, "value" => value}

  defp reference_wire_part(%{name: name, value: bytes, filename: filename, mime_type: mime}) do
    %{
      "name" => name,
      "fileName" => filename,
      "mimeType" => mime,
      "size" => byte_size(bytes),
      "bytesBase64" => Base.encode64(bytes)
    }
  end

  defp reference_wire_part(%{name: name, value: value}), do: %{"name" => name, "value" => value}

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

  defp request,
    do: %{
      prompt: " A mountain 雪\n",
      model: " deepinfra/black-forest-labs/FLUX-1-schnell ",
      timeout_ms: 5_000
    }

  defp config(base_url), do: %{api_key: "deepinfra-image-fixture", base_url: base_url}

  defp body,
    do: %{
      "model" => "black-forest-labs/FLUX-1-schnell",
      "prompt" => " A mountain 雪\n",
      "n" => 1,
      "size" => "1024x1024",
      "response_format" => "b64_json"
    }

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> DeepInfra.generate(request, config) end)
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

  defp multipart_parts(body, boundary) do
    body
    |> :binary.split("--" <> boundary, [:global])
    |> Enum.reject(&(&1 in ["", "--\r\n"]))
    |> Enum.map(fn "\r\n" <> part ->
      [headers, body] = :binary.split(part, "\r\n\r\n")
      value = binary_part(body, 0, byte_size(body) - 2)
      [_, name] = Regex.run(~r/; name="([^"]*)"/, headers)
      result = %{name: name, value: value}

      case Regex.run(~r/; filename="([^"]*)"/, headers) do
        [_, filename] ->
          [_, mime_type] = Regex.run(~r/content-type: ([^\r]*)/i, headers)
          Map.merge(result, %{filename: filename, mime_type: mime_type})

        nil ->
          result
      end
    end)
  end
end
