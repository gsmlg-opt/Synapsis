defmodule Synapsis.Provider.ImageGeneration.FalFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.Fal

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/fal-image-generation.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "fallback preserves prompt and model prefix while projecting generation and singular edits" do
    req = %{
      prompt: " A mountain 雪\n",
      model: "\uFEFF fal/fal-ai/custom \u00A0",
      timeout_ms: 5_000,
      count: 3,
      aspect_ratio: " 9:16 ",
      resolution: "2K",
      output_format: "jpeg"
    }

    cfg =
      Map.put(config("\uFEFF https://images.example/relay/// \u00A0"), :request, %{
        headers: %{"X-Context" => " ordinary "}
      })

    assert {:ok, built} = Fal.build_request(req, cfg)
    assert built.url == "https://images.example/relay/fal/fal-ai/custom"
    assert built.model == "fal/fal-ai/custom"
    assert built.headers["x-context"] == "ordinary"
    assert built.timeout_ms == 5_000
    assert built.max_response_bytes == 16 * 1024 * 1024
    assert built.max_image_bytes == 64 * 1024 * 1024

    assert built.body == %{
             "prompt" => " A mountain 雪\n",
             "num_images" => 3,
             "output_format" => "jpeg",
             "image_size" => %{"width" => 1152, "height" => 2048}
           }

    edit = %{
      prompt: "edit",
      model: "fal-ai/custom/image-to-image/revision",
      timeout_ms: 5_000,
      resolution: "2K",
      input_images: [%{data: <<0, 255, 1>>, mime_type: " Image/WebP; source=raw "}]
    }

    assert {:ok, built} = Fal.build_request(edit, config("https://images.example"))
    assert built.url == "https://images.example/fal-ai/custom/image-to-image/revision"

    assert built.body == %{
             "prompt" => "edit",
             "num_images" => 1,
             "output_format" => "png",
             "image_size" => %{"width" => 2048, "height" => 2048},
             "image_url" => "data:Image/WebP; source=raw;base64,AP8B"
           }
  end

  test "exact GPT 2.5 rewrites its text path and retains sixteen ordered raw references" do
    req = %{
      prompt: "sixteen references",
      model: "openai/gpt-image-2.5/sunburst/text-to-image",
      timeout_ms: 5_000,
      count: 4,
      aspect_ratio: "2.35:1",
      quality: "xhigh",
      output_format: "webp",
      background: "transparent",
      input_images: Enum.map(0..15, &%{data: <<&1>>, filename: "ignored-#{&1}.bin"})
    }

    assert {:ok, built} = Fal.build_request(req, config("https://images.example"))
    assert built.model == "openai/gpt-image-2.5/sunburst/edit"
    assert built.url == "https://images.example/openai/gpt-image-2.5/sunburst/edit"

    assert built.body == %{
             "prompt" => "sixteen references",
             "num_images" => 4,
             "output_format" => "webp",
             "quality" => "xhigh",
             "background" => "transparent",
             "image_size" => %{"width" => 1536, "height" => 656},
             "image_urls" => [
               "data:image/png;base64,AA==",
               "data:image/png;base64,AQ==",
               "data:image/png;base64,Ag==",
               "data:image/png;base64,Aw==",
               "data:image/png;base64,BA==",
               "data:image/png;base64,BQ==",
               "data:image/png;base64,Bg==",
               "data:image/png;base64,Bw==",
               "data:image/png;base64,CA==",
               "data:image/png;base64,CQ==",
               "data:image/png;base64,Cg==",
               "data:image/png;base64,Cw==",
               "data:image/png;base64,DA==",
               "data:image/png;base64,DQ==",
               "data:image/png;base64,Dg==",
               "data:image/png;base64,Dw=="
             ]
           }
  end

  test "Krea uses size-derived native ratio and style references without output count or format" do
    req = %{
      prompt: "style",
      model: "krea/v2/medium/text-to-image",
      timeout_ms: 5_000,
      count: 1,
      size: " 1024X1536 ",
      provider_options: %{"fal" => %{"creativity" => " HIGH "}},
      input_images: [
        %{data: "first", mime_type: " "},
        %{data: "second", mime_type: " image/jpeg ", filename: "ignored.png"}
      ]
    }

    assert {:ok, built} = Fal.build_request(req, config("https://images.example/"))
    assert built.model == "krea/v2/medium/text-to-image"
    assert built.url == "https://images.example/krea/v2/medium/text-to-image"

    assert built.body == %{
             "prompt" => "style",
             "creativity" => "high",
             "aspect_ratio" => "2:3",
             "image_style_references" => [
               %{"image_url" => "data:image/png;base64,Zmlyc3Q="},
               %{"image_url" => "data:image/jpeg;base64,c2Vjb25k"}
             ]
           }
  end

  test "ordinary Grok POST downloads all four URLs in order and its linked HTTP owner exits normally",
       %{
         fixture: fixture,
         tasks: tasks
       } do
    owner = self()

    for {index, mime, bytes} <- [
          {1, "image/png", "first"},
          {2, "Image/JPEG; source=raw", <<255, 216, 255, 0>>},
          {3, "image/svg+xml", "<svg/>"},
          {4, nil, "fourth"}
        ] do
      Gaoxy.Test.expect_once(fixture, "GET", "/assets/#{index}", fn conn ->
        send(owner, {:download, index})
        assert Plug.Conn.get_req_header(conn, "x-context") == []
        conn = if mime, do: Plug.Conn.put_resp_header(conn, "content-type", mime), else: conn
        Plug.Conn.resp(conn, 200, bytes)
      end)
    end

    Gaoxy.Test.expect_once(
      fixture,
      "POST",
      "/relay/xai/grok-imagine-image/quality/edit",
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]

        assert Jason.decode!(raw) == %{
                 "prompt" => "four ordinary images",
                 "num_images" => 4,
                 "output_format" => "png",
                 "aspect_ratio" => "19.5:9",
                 "resolution" => "2k",
                 "image_urls" => [
                   "data:image/png;base64,YQ==",
                   "data:image/jpeg;base64,Yg==",
                   "data:image/png;base64,Yw=="
                 ]
               }

        send(owner, {:http_waiting, self()})

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
            "prompt" => "\uFEFF returned prompt 雪 \u00A0",
            "images" =>
              Enum.map(1..4, fn index ->
                %{
                  "url" => " " <> Gaoxy.Test.url(fixture, "/assets/#{index}") <> " ",
                  "content_type" => "ignored/type",
                  "file_name" => "ignored.bin"
                }
              end)
          })
        )
      end
    )

    req = %{
      prompt: "four ordinary images",
      model: "xai/grok-imagine-image/quality",
      timeout_ms: 5_000,
      count: 4,
      aspect_ratio: "19.5:9",
      resolution: "2K",
      input_images: [%{data: "a"}, %{data: "b", mime_type: "image/jpeg"}, %{data: "c"}]
    }

    cfg =
      Map.put(config(Gaoxy.Test.url(fixture, "/relay")), :request, %{
        headers: %{"X-Context" => "ordinary"}
      })

    caller = Task.Supervisor.async_nolink(tasks, fn -> Fal.generate(req, cfg) end)
    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, &(is_pid(&1) and &1 != tasks))
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)

    assert result == %{
             model: "xai/grok-imagine-image/quality/edit",
             metadata: %{prompt: "returned prompt 雪"},
             images: [
               %{data: "first", mime_type: "image/png", filename: "image-1.png"},
               %{
                 data: <<255, 216, 255, 0>>,
                 mime_type: "Image/JPEG; source=raw",
                 filename: "image-2.jpg"
               },
               %{data: "<svg/>", mime_type: "image/svg+xml", filename: "image-3.svg"},
               %{data: "fourth", mime_type: "image/png", filename: "image-4.png"}
             ]
           }

    assert for(
             _ <- 1..4,
             do:
               (
                 assert_receive {:download, index}
                 index
               )
           ) == [1, 2, 3, 4]

    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all 178 explicit source cases match complete plans and actual ordered HTTP results", %{
    fixture: fixture,
    tasks: tasks
  } do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert length(rows) == 180
    assert length(Enum.uniq_by(rows, & &1["id"])) == 180

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-default-model-timeout",
             "source-only-configured-header"
           ]

    assert capture["providerDescriptor"]["models"] == [
             "fal-ai/flux/dev",
             "fal-ai/flux/dev/image-to-image",
             "krea/v2/medium/text-to-image",
             "krea/v2/large/text-to-image",
             "openai/gpt-image-2.5/flare/text-to-image",
             "openai/gpt-image-2.5/flare/edit",
             "openai/gpt-image-2.5/sunburst/text-to-image",
             "openai/gpt-image-2.5/sunburst/edit"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 178

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row["config"])
      assert {:ok, built} = Fal.build_request(req, cfg)
      assert built.url == row["request"]["url"], id
      assert built.body == row["request"]["body"], id
      assert built.body == row["request"]["jsonBody"], id
      assert built.body == Jason.decode!(row["request"]["rawBody"]), id
      assert built.headers == row["request"]["headers"], id
      assert built.model == row["result"]["model"], id
      assert built.max_response_bytes == row["request"]["maxBytes"], id
      assert built.timeout_ms == min(2_147_000_000, max(1, floor(row["input"]["timeoutMs"]))), id
      assert row["inputAfter"] == row["input"], id
      assert_source_lifecycle(row, built)

      prefix = "/reference/" <> id
      local_response = reference_downloads(fixture, prefix, row)
      owner = self()

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/" <> built.model, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == row["request"]["body"], id

        for {name, value} <- built.headers do
          assert Plug.Conn.get_req_header(conn, name) == [value], id
        end

        send(owner, {:reference_post, id})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(local_response))
      end)

      local_config = Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix))

      assert {:ok, result} =
               tasks
               |> Task.Supervisor.async_nolink(fn -> Fal.generate(req, local_config) end)
               |> Task.await(10_000)

      assert result == reference_result(row["result"]), id
      assert_receive {:reference_post, ^id}

      observed =
        for _download <- row["downloads"] do
          assert_receive {:reference_download, ^id, url}
          url
        end

      assert observed == Enum.map(row["downloads"], & &1["url"]), id
    end
  end

  defp assert_source_lifecycle(row, built) do
    id = row["id"]
    post = row["request"]
    assert post["method"] == "POST", id
    assert post["initSupplied"], id
    assert post["releaseCount"] == 1, id
    calls = [post | row["downloads"]]

    for call <- calls do
      assert call["timeoutMs"] == built.timeout_ms + row["clock"]["startMs"] - call["atMs"], id
      assert call["timeoutMs"] > 0 and call["timeoutMs"] <= built.timeout_ms, id
    end

    for [earlier, later] <- Enum.chunk_every(calls, 2, 1, :discard) do
      assert earlier["timeoutMs"] > later["timeoutMs"], id
    end

    for download <- row["downloads"] do
      assert download["method"] == "GET", id
      assert download["headers"] == %{}, id
      assert download["initSupplied"] == false, id
      assert download["releaseCount"] == 1, id
      assert download["maxBytes"] == built.max_image_bytes, id
    end

    assert Enum.map(row["releaseCalls"], &{&1["kind"], &1["url"], &1["releaseCount"]}) ==
             Enum.map(row["downloads"], &{"download", &1["url"], 1}) ++ [{"post", post["url"], 1}],
           id

    assert row["releaseCount"] == length(row["downloads"]) + 1, id
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

    if Map.has_key?(input, "inputImages") do
      Map.put(
        req,
        :input_images,
        Enum.map(input["inputImages"], fn image ->
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

    if Map.has_key?(input, "mediaMaxMb"),
      do: Map.put(cfg, :max_image_bytes, floor(input["mediaMaxMb"] * 1024 * 1024)),
      else: cfg
  end

  defp reference_result(result) do
    expected = %{
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

    if Map.has_key?(result, "metadata"),
      do: Map.put(expected, :metadata, %{prompt: result["metadata"]["prompt"]}),
      else: expected
  end

  defp reference_downloads(fixture, prefix, row) do
    owner = self()

    local_urls =
      Enum.zip(row["downloads"], row["response"]["downloads"])
      |> Enum.with_index(1)
      |> Map.new(fn {{download, response}, index} ->
        path = prefix <> "/assets/#{index}"

        Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
          send(owner, {:reference_download, row["id"], download["url"]})

          conn =
            if Map.has_key?(response, "mimeType"),
              do: Plug.Conn.put_resp_header(conn, "content-type", response["mimeType"]),
              else: conn

          Plug.Conn.resp(conn, 200, Base.decode64!(response["bytesBase64"]))
        end)

        {download["url"], Gaoxy.Test.url(fixture, path)}
      end)

    Map.update!(row["response"]["json"], "images", fn entries ->
      Enum.map(entries, fn entry ->
        Map.put(entry, "url", Map.fetch!(local_urls, String.trim(entry["url"])))
      end)
    end)
  end

  defp config(base_url), do: %{api_key: "explicit-fixture-key", base_url: base_url}
end
