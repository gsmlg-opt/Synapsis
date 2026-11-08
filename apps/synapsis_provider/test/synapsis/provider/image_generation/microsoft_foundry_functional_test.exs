defmodule Synapsis.Provider.ImageGeneration.MicrosoftFoundryFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.MicrosoftFoundry

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/microsoft-foundry-image-generation.json",
               __DIR__
             )
  @ids ~w(default-count-size explicit-count-one model-2.5-flash model-2e model-2 model-2-efficient trimmed-model-prompt prefixed-model custom-deployment-generation-metadata custom-deployment-generation-no-metadata javascript-whitespace size-768 size-768x1365 size-1365x768 size-800x1000 size-leading-zeros unused-options endpoint-openai-v1 endpoint-anthropic endpoint-prefix endpoint-query-trailing endpoint-hostcase-defaultport endpoint-existing-mai-v1 edit-default-png edit-flash edit-jpeg edit-jpg edit-trimmed-name edit-path-name edit-custom-deployment-metadata edit-unused-size-options response-explicit-mime response-sniff-jpeg response-sniff-webp response-png-fallback base64-unpadded base64-whitespace media-cap-floor media-cap-larger source-only-default-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "default generation normalizes the endpoint and sends only MAI JSON fields", %{
    fixture: fixture,
    tasks: tasks
  } do
    cfg = %{
      api_key: "synthetic-explicit-key",
      base_url: "\uFEFF https://FOUNDRY.example:443/team/OpenAI/v1/?api=one#two \u00A0",
      models: [%{id: "studio", name: "MAI-Image-2.5"}],
      request: %{headers: %{"X-Image-Profile" => " studio ", "Content-Type" => "text/plain"}}
    }

    req = %{request() | model: "\uFEFF studio \u2029"}
    assert {:ok, built} = MicrosoftFoundry.build_request(req, cfg)

    assert built == %{
             url: "https://foundry.example/team/mai/v1/images/generations",
             model: "studio",
             headers: %{
               "api-key" => "synthetic-explicit-key",
               "x-image-profile" => "studio",
               "content-type" => "application/json"
             },
             timeout_ms: 5_000,
             max_image_bytes: 64 * 1024 * 1024,
             max_response_bytes: div(64 * 1024 * 1024 * 4 + 2, 3) + 1024 * 1024,
             body: %{
               "model" => "studio",
               "prompt" => " A mountain 雪\n",
               "width" => 1024,
               "height" => 1024
             }
           }

    Gaoxy.Test.expect_once(fixture, "POST", "/team/mai/v1/images/generations", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == built.body
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      json_response(conn, %{"data" => [%{"b64_json" => "Z2VuZXJhdGVk"}]})
    end)

    assert {:ok, result} =
             generate(
               tasks,
               req,
               Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, "/team/openai/v1"))
             )

    assert result == %{
             model: "studio",
             images: [
               %{
                 data: "generated",
                 mime_type: "image/png",
                 filename: "microsoft-foundry-image-1.png"
               }
             ]
           }
  end

  test "single edit sends ordered multipart with original bytes and trimmed path filename", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = <<0, 255, 128, 13, 10, 1>>

    req =
      Map.merge(request(), %{
        model: "microsoft-foundry/studio",
        size: "1024x1024",
        count: 1,
        quality: "high",
        resolution: "4K",
        aspect_ratio: "16:9",
        output_format: "webp",
        background: "transparent",
        provider_options: %{unused: true},
        input_images: [%{data: bytes, mime_type: " Image/JPG ", filename: " /photos/雪.jpg "}]
      })

    cfg = %{
      api_key: "synthetic-explicit-key",
      base_url: Gaoxy.Test.url(fixture, "/edit/anthropic/v1"),
      models: [%{id: "microsoft-foundry/studio", name: " MAI-Image-2.5-Flash "}],
      request: %{headers: %{"Content-Type" => "text/plain"}}
    }

    assert {:ok, built} = MicrosoftFoundry.build_request(req, cfg)
    assert built.headers == %{"api-key" => "synthetic-explicit-key"}

    assert built.form == [
             {"model", "microsoft-foundry/studio"},
             {"prompt", " A mountain 雪\n"},
             {"image", {bytes, filename: "/photos/雪.jpg", content_type: "image/jpeg"}}
           ]

    Gaoxy.Test.expect_once(fixture, "POST", "/edit/mai/v1/images/edits", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)

      assert multipart_parts(raw, boundary) == [
               %{name: "model", value: "microsoft-foundry/studio"},
               %{name: "prompt", value: " A mountain 雪\n"},
               %{name: "image", value: bytes, filename: "/photos/雪.jpg", mime_type: "image/jpeg"}
             ]

      json_response(conn, %{"data" => [%{"b64_json" => "ZWRpdGVk"}]})
    end)

    assert {:ok, result} = generate(tasks, req, cfg)
    assert result.model == "microsoft-foundry/studio"

    assert result.images == [
             %{data: "edited", mime_type: "image/png", filename: "microsoft-foundry-image-1.png"}
           ]
  end

  test "ordinary single outputs sniff MIME and prefer explicit MIME and revised prompt", %{
    fixture: fixture,
    tasks: tasks
  } do
    req = Map.merge(request(), %{model: "custom-deployment", size: "0768x01365", count: 1})
    jpeg = <<255, 216, 255, 0>>
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    webp = "RIFF1234WEBPpayload"

    examples = [
      {%{"b64_json" => Base.encode64(jpeg), "revised_prompt" => " revised snow \n"},
       %{
         data: jpeg,
         mime_type: "image/jpeg",
         filename: "microsoft-foundry-image-1.jpg",
         revised_prompt: "revised snow"
       }},
      {%{"b64_json" => Base.encode64(png)},
       %{data: png, mime_type: "image/png", filename: "microsoft-foundry-image-1.png"}},
      {%{"b64_json" => Base.encode64(webp)},
       %{data: webp, mime_type: "image/webp", filename: "microsoft-foundry-image-1.webp"}},
      {%{"b64_json" => Base.encode64(jpeg), "mime_type" => " Image/SVG+XML ; profile=one "},
       %{
         data: jpeg,
         mime_type: "Image/SVG+XML ; profile=one",
         filename: "microsoft-foundry-image-1.svg"
       }},
      {%{"b64_json" => "b3BhcXVl"},
       %{data: "opaque", mime_type: "image/png", filename: "microsoft-foundry-image-1.png"}}
    ]

    for {{entry, expected}, index} <- Enum.with_index(examples, 1) do
      prefix = "/assets/#{index}"

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/mai/v1/images/generations", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "model" => "custom-deployment",
                 "prompt" => " A mountain 雪\n",
                 "width" => 768,
                 "height" => 1365
               }

        json_response(conn, %{"data" => [entry]})
      end)

      assert {:ok, result} = generate(tasks, req, config(Gaoxy.Test.url(fixture, prefix)))
      assert result == %{model: "custom-deployment", images: [expected]}
    end
  end

  test "successful linked HTTP owner exits normally after chunked BOM JSON", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/owner/mai/v1/images/generations", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:http_waiting, self()})

      receive do
        :respond -> :ok
      after
        2_000 -> flunk("ordinary response was not released")
      end

      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, <<0xEF, 0xBB>>)
      {:ok, conn} = Plug.Conn.chunk(conn, <<0xBF>> <> "{\"data\":[")
      {:ok, conn} = Plug.Conn.chunk(conn, "{\"b64_json\":\"bm9ybWFs\"}]}")
      conn
    end)

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        MicrosoftFoundry.generate(request(), config(Gaoxy.Test.url(fixture, "/owner")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)

    assert result.images == [
             %{data: "normal", mime_type: "image/png", filename: "microsoft-foundry-image-1.png"}
           ]

    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all 39 comparable fixed-source rows match full plans, actual HTTP and results", %{
    fixture: fixture,
    tasks: tasks
  } do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.map(rows, & &1["id"]) == @ids

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-default-timeout",
             "source-only-configured-header"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert Enum.count(comparable) == 39

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      original_req = req
      original_cfg = cfg
      assert {:ok, built} = MicrosoftFoundry.build_request(req, cfg)

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
      assert row["inputAfter"] == row["input"], id
      assert row["releaseCount"] == 1, id
      assert row["request"]["releaseCount"] == 1, id
      assert row["releaseCalls"] == [%{"releaseCount" => 1, "atMs" => 100_010}], id
      assert length(row["result"]["images"]) == 1, id

      prefix = "/reference/" <> id
      action = if row["request"]["kind"] == "multipart", do: "edits", else: "generations"

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/mai/v1/images/" <> action, fn conn ->
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

        json_response(conn, row["response"]["json"])
      end)

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"]), id
      assert req == original_req, id
      assert cfg == original_cfg, id
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

    cfg =
      if input["models"],
        do: Map.put(cfg, :models, Enum.map(input["models"], &%{id: &1["id"], name: &1["name"]})),
        else: cfg

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

  defp request, do: %{prompt: " A mountain 雪\n", model: "MAI-Image-2.5", timeout_ms: 5_000}
  defp config(base_url), do: %{api_key: "synthetic-explicit-key", base_url: base_url}

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> MicrosoftFoundry.generate(request, config) end)
    |> Task.await(10_000)
  end

  defp json_response(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
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
