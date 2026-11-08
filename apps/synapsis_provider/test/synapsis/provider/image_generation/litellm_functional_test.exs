defmodule Synapsis.Provider.ImageGeneration.LiteLLMFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.LiteLLM

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/litellm-image-generation.json",
               __DIR__
             )
  @ids ~w(default-count-size explicit-model-prompt litellm-prefixed-model count-four size-256 size-512 size-1024 size-1024x1536 size-portrait size-1536x1024 size-landscape size-2048 size-2048x1152 size-3840x2160 size-2160x3840 size-untrimmed unused-options edit-defaults edit-count-four edit-five-ordered edit-explicit-mime-filename edit-unicode-path-name edit-default-jpeg-filename custom-base javascript-whitespace ordered-inline-default-png explicit-mime-wins base64-unpadded base64-whitespace four-ordered-downloads edit-four-ordered-downloads json-bom-raw-chunks media-cap-floor media-cap-larger source-only-default-model-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "JSON retains prefixed model, prompt, size bytes and four ordered inline assets", %{
    fixture: fixture,
    tasks: tasks
  } do
    req =
      Map.merge(request(), %{
        size: " \uFEFF1024x1792\u00A0 ",
        count: 3,
        quality: "high",
        output_format: "webp",
        background: "transparent",
        aspect_ratio: "16:9",
        resolution: "4K",
        provider_options: %{litellm: %{unused: true}}
      })

    cfg = %{
      api_key: "synthetic-explicit-key",
      base_url: "\uFEFF https://images.example/custom/// \u00A0",
      request: %{headers: %{"X-Image-Profile" => " studio ", "Content-Type" => "text/plain"}}
    }

    assert {:ok, built} = LiteLLM.build_request(req, cfg)

    assert built == %{
             url: "https://images.example/custom/images/generations",
             model: "litellm/custom-model",
             headers: %{
               "authorization" => "Bearer synthetic-explicit-key",
               "x-image-profile" => "studio",
               "content-type" => "application/json"
             },
             timeout_ms: 5_000,
             max_image_bytes: 64 * 1024 * 1024,
             max_downloads: 4,
             max_response_bytes: div(64 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024,
             body: %{
               "model" => "litellm/custom-model",
               "prompt" => " A mountain 雪\n",
               "n" => 3,
               "size" => " \uFEFF1024x1792\u00A0 "
             }
           }

    jpeg = <<255, 216, 255, 0>>
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    webp = "RIFF1234WEBPpayload"

    Gaoxy.Test.expect_once(fixture, "POST", "/json/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == built.body
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      json_response(conn, %{
        "data" => [
          %{"b64_json" => Base.encode64(jpeg), "revised_prompt" => " revised snow \n"},
          %{"b64_json" => Base.encode64(webp)},
          %{"b64_json" => Base.encode64(png), "mime_type" => " Image/SVG+XML ; profile=one "},
          %{"b64_json" => Base.encode64("opaque")}
        ],
        "usage" => %{"total_tokens" => 9}
      })
    end)

    assert {:ok, result} =
             generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, "/json")))

    assert result == %{
             model: "litellm/custom-model",
             images: [
               %{
                 data: jpeg,
                 mime_type: "image/png",
                 filename: "image-1.png",
                 revised_prompt: "revised snow"
               },
               %{data: webp, mime_type: "image/png", filename: "image-2.png"},
               %{data: png, mime_type: "Image/SVG+XML ; profile=one", filename: "image-3.svg"},
               %{data: "opaque", mime_type: "image/png", filename: "image-4.png"}
             ]
           }
  end

  test "one reference uses singular ordered multipart and retains requested count", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<0, 255, 128, 13, 10, 1>>

    req =
      Map.merge(request(), %{
        count: 4,
        input_images: [%{data: bytes, mime_type: " Image/JPEG ", filename: " /photos/snow.jpg "}]
      })

    cfg = %{
      api_key: "synthetic-explicit-key",
      base_url: "https://images.example/v1///",
      request: %{headers: %{"Content-Type" => "text/plain", "X-Image-Profile" => " studio "}}
    }

    assert {:ok, built} = LiteLLM.build_request(req, cfg)
    assert built.url == "https://images.example/v1/images/edits"
    assert built.max_downloads == 4
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 4 * 4 + 2, 3) + 1024 * 1024

    assert built.headers == %{
             "authorization" => "Bearer synthetic-explicit-key",
             "x-image-profile" => "studio"
           }

    assert built.form == [
             {"model", "litellm/custom-model"},
             {"prompt", " A mountain 雪\n"},
             {"n", "4"},
             {"size", "1024x1024"},
             {"image", {bytes, filename: "/photos/snow.jpg", content_type: "image/jpeg"}}
           ]

    Gaoxy.Test.expect_once(fixture, "POST", "/single/images/edits", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]
      {parts, conn} = read_multipart(conn)

      assert parts == [
               %{name: "model", value: "litellm/custom-model"},
               %{name: "prompt", value: " A mountain 雪\n"},
               %{name: "n", value: "4"},
               %{name: "size", value: "1024x1024"},
               %{
                 name: "image",
                 value: bytes,
                 filename: "/photos/snow.jpg",
                 mime_type: "image/jpeg"
               }
             ]

      json_response(conn, %{"data" => [%{"b64_json" => Base.encode64("edited")}]})
    end)

    assert {:ok, result} =
             generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, "/single")))

    assert result == %{
             model: "litellm/custom-model",
             images: [%{data: "edited", mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "five reference files retain order, original bytes, MIME and generated names", %{
    fixture: fixture,
    tasks: tasks
  } do
    req =
      Map.merge(request(), %{
        count: 2,
        size: " \uFEFF ",
        input_images: [
          %{data: <<0, 255, 1>>},
          %{data: "two", mime_type: " Image/JPEG "},
          %{data: "three", mime_type: " image/SVG+XML ", filename: " dir/雪.svg "},
          %{data: "four", mime_type: " IMAGE/WEBP "},
          %{data: <<128, 0, 255>>, mime_type: " image/vnd.custom+xml "}
        ]
      })

    expected = [
      %{name: "model", value: "litellm/custom-model"},
      %{name: "prompt", value: " A mountain 雪\n"},
      %{name: "n", value: "2"},
      %{name: "size", value: " \uFEFF "},
      %{name: "image[]", value: <<0, 255, 1>>, filename: "image-1.png", mime_type: "image/png"},
      %{name: "image[]", value: "two", filename: "image-2.jpg", mime_type: "image/jpeg"},
      %{name: "image[]", value: "three", filename: "dir/雪.svg", mime_type: "image/svg+xml"},
      %{name: "image[]", value: "four", filename: "image-4.webp", mime_type: "image/webp"},
      %{
        name: "image[]",
        value: <<128, 0, 255>>,
        filename: "image-5.vnd.custom+xml",
        mime_type: "image/vnd.custom+xml"
      }
    ]

    Gaoxy.Test.expect_once(fixture, "POST", "/five/images/edits", fn conn ->
      {parts, conn} = read_multipart(conn)
      assert parts == expected
      json_response(conn, %{"data" => [%{"b64_json" => Base.encode64("five")}]})
    end)

    assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, "/five")))

    assert result == %{
             model: "litellm/custom-model",
             images: [%{data: "five", mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "four ordered URL downloads use transport MIME and linked HTTP owner exits normally", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    sources = [
      {<<255, 216, 255>>, "Image/WebP; profile=one", "image/webp", "webp"},
      {"two", "image/jpeg", "image/jpeg", "jpg"},
      {<<0, 255, 128>>, "image/png; charset=binary", "image/png", "png"},
      {"four", "image/avif", "image/avif", "avif"}
    ]

    entries =
      Enum.with_index(sources, 1)
      |> Enum.map(fn {{bytes, content_type, _mime, _extension}, index} ->
        path = "/ordered/assets/#{index}"

        Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
          send(test_pid, {:download, index})

          conn
          |> Plug.Conn.put_resp_header("content-type", content_type)
          |> Plug.Conn.resp(200, bytes)
        end)

        %{"url" => Gaoxy.Test.url(fixture, path), "revised_prompt" => " image #{index} "}
      end)

    Gaoxy.Test.expect_once(fixture, "POST", "/ordered/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "model" => "litellm/custom-model",
               "prompt" => " A mountain 雪\n",
               "n" => 1,
               "size" => "1024x1024"
             }

      send(test_pid, {:http_waiting, self()})

      receive do
        :respond -> :ok
      after
        2_000 -> flunk("ordinary response was not released")
      end

      json_response(conn, %{"data" => entries})
    end)

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        LiteLLM.generate(request(), config(Gaoxy.Test.url(fixture, "/ordered")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)

    assert result == %{
             model: "litellm/custom-model",
             images:
               Enum.with_index(sources, 1)
               |> Enum.map(fn {{bytes, _type, mime, extension}, index} ->
                 %{
                   data: bytes,
                   mime_type: mime,
                   filename: "image-#{index}.#{extension}",
                   revised_prompt: "image #{index}"
                 }
               end)
           }

    assert_receive {:download, 1}
    assert_receive {:download, 2}
    assert_receive {:download, 3}
    assert_receive {:download, 4}
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
    assert Enum.count(comparable) == 34

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = LiteLLM.build_request(req, cfg)

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
      assert built.max_downloads == 4, id
      assert built.max_image_bytes == Map.get(cfg, :max_image_bytes, 64 * 1024 * 1024), id
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
      model: "\uFEFF litellm/custom-model \u2029",
      timeout_ms: 5_000
    }

  defp config(base_url), do: %{api_key: "synthetic-explicit-key", base_url: base_url}

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> LiteLLM.generate(request, config) end)
    |> Task.await(10_000)
  end

  defp json_response(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  defp read_multipart(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)

    parts = multipart_parts(body, boundary)

    {parts, conn}
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
