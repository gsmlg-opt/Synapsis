defmodule Synapsis.Provider.ImageGeneration.MiniMaxFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.MiniMax

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/minimax-image-generation.json",
               __DIR__
             )
  @ids ~w(default-count explicit-model-prompt minimax-prefixed-model portal-provider count-one count-nine aspect-1-1 aspect-16-9 aspect-4-3 aspect-3-2 aspect-2-3 aspect-3-4 aspect-9-16 aspect-21-9 aspect-js-trim input-default-mime input-raw-mime-filename-ignored ordered-opaque-results base64-unpadded base64-whitespace metadata-ignored configured-cn-region portal-configured-cn-region media-cap-floor media-cap-larger source-only-default-model-timeout source-only-configured-header)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "explicit JSON plan preserves raw model and prompt with source count and aspect" do
    req =
      Map.merge(request(), %{
        model: " minimax/image-01 ",
        count: 9,
        aspect_ratio: "\uFEFF 16:9 \u00A0",
        size: "1024x1024",
        resolution: "4K",
        provider_options: %{unused: true}
      })

    assert {:ok, built} =
             MiniMax.build_request(req, config("\uFEFF https://images.example/custom/// \u00A0"))

    assert built.url == "https://images.example/custom/v1/image_generation"
    assert built.model == " minimax/image-01 "

    assert built.body == %{
             "model" => " minimax/image-01 ",
             "prompt" => " A mountain 雪\n",
             "response_format" => "base64",
             "n" => 9,
             "aspect_ratio" => "16:9"
           }

    assert built.headers == %{
             "authorization" => "Bearer minimax-image-fixture",
             "content-type" => "application/json"
           }

    assert built.timeout_ms == 5_000
    assert built.max_image_bytes == 64 * 1024 * 1024
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 9 * 4 + 2, 3) + 1024 * 1024
  end

  test "first ordered reference uses raw MIME or JPEG without forwarding filenames" do
    for {mime, expected} <- [
          {nil, "image/jpeg"},
          {"", "image/jpeg"},
          {" Image/Custom ; profile=one ", " Image/Custom ; profile=one "}
        ] do
      req =
        Map.put(request(), :input_images, [
          %{data: <<0, 255, 128>>, mime_type: mime, filename: "ignored.png"}
        ])

      assert {:ok, built} =
               MiniMax.build_request(
                 req,
                 Map.put(config("https://images.example"), :provider_id, "minimax-portal")
               )

      assert built.body ==
               Map.put(body(), "subject_reference", [
                 %{"type" => "character", "image_file" => "data:" <> expected <> ";base64,AP+A"}
               ])
    end
  end

  test "actual JSON POST returns ordered fixed PNG assets and canonical base64", %{
    fixture: fixture,
    tasks: tasks
  } do
    cfg =
      Map.put(config(Gaoxy.Test.url(fixture, "/ordinary")), :request, %{
        headers: %{"X-Image-Profile" => " \uFEFFstudio \u00A0", "Content-Type" => "text/plain"}
      })

    Gaoxy.Test.expect_once(fixture, "POST", "/ordinary/v1/image_generation", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body()
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer minimax-image-fixture"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "x-image-profile") == ["studio"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{"image_base64" => ["b25l", "dHdvIQ", " dG\thy\nZWU=\r"]},
          "metadata" => %{"success_count" => 3, "failed_count" => 0},
          "id" => "ignored-id",
          "base_resp" => %{"status_code" => 0}
        })
      )
    end)

    assert {:ok, result} = generate(tasks, request(), cfg)

    assert result == %{
             model: "image-01",
             images: [
               %{data: "one", mime_type: "image/png", filename: "image-1.png"},
               %{data: "two!", mime_type: "image/png", filename: "image-2.png"},
               %{data: "three", mime_type: "image/png", filename: "image-3.png"}
             ]
           }
  end

  test "successful linked HTTP owner exits normally after one POST", %{
    fixture: fixture,
    tasks: tasks
  } do
    test_pid = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/owner/v1/image_generation", fn conn ->
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
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"image_base64" => ["bm9ybWFs"]}}))
    end)

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        MiniMax.generate(request(), config(Gaoxy.Test.url(fixture, "/owner")))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, fn pid -> is_pid(pid) and pid != tasks end)
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, result} = Task.await(caller, 5_000)

    assert result == %{
             model: "image-01",
             images: [%{data: "normal", mime_type: "image/png", filename: "image-1.png"}]
           }

    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "successful chunked JSON and decoded image meet explicit exact bounds", %{
    fixture: fixture,
    tasks: tasks
  } do
    bytes = :binary.copy(<<0, 255, 128>>, 257)
    raw = Jason.encode!(%{"data" => %{"image_base64" => [Base.encode64(bytes)]}})

    Gaoxy.Test.expect_once(fixture, "POST", "/bounded/v1/image_generation", fn conn ->
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
             model: "image-01",
             images: [%{data: bytes, mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "all comparable fixed-source rows match full plans, actual POSTs and exact results", %{
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
    assert Enum.count(comparable) == 25

    for row <- comparable do
      id = row["id"]
      req = reference_request(row["input"])
      cfg = reference_config(row)
      assert {:ok, built} = MiniMax.build_request(req, cfg)

      assert %{
               "url" => built.url,
               "method" => "POST",
               "body" => built.body,
               "headers" => built.headers,
               "timeoutMs" => built.timeout_ms,
               "maxBytes" => built.max_response_bytes
             } == Map.take(row["request"], ~w(url method body headers timeoutMs maxBytes)),
             id

      assert built.model == row["result"]["model"], id
      assert row["releaseCount"] == 1, id
      assert row["request"]["releaseCount"] == 1, id
      assert row["inputAfter"] == row["input"], id
      assert length(req[:input_images] || []) <= 1, id
      assert (req[:count] || 1) in 1..9, id

      prefix = "/reference/" <> id

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/v1/image_generation", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == row["request"]["body"], id

        for {name, value} <- row["request"]["headers"] do
          assert Plug.Conn.get_req_header(conn, name) == [value], id
        end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(row["response"]["json"]))
      end)

      assert {:ok, result} =
               generate(tasks, req, Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix)))

      assert result == reference_result(row["result"]), id
    end
  end

  defp reference_request(input) do
    req = %{prompt: input["prompt"], model: input["model"], timeout_ms: input["timeoutMs"]}

    req =
      Enum.reduce(
        [
          {"count", :count},
          {"aspectRatio", :aspect_ratio},
          {"size", :size},
          {"resolution", :resolution},
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
            filename: image["fileName"]
          }
        end)
      )
    else
      req
    end
  end

  defp reference_config(row) do
    cfg = %{
      api_key: "synthetic-explicit-key",
      base_url: row["config"]["effectiveBaseUrl"],
      provider_id: row["providerId"]
    }

    if cap = row["config"]["mediaMaxMb"],
      do: Map.put(cfg, :max_image_bytes, max(64 * 1024 * 1024, floor(cap * 1024 * 1024))),
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

  defp request, do: %{prompt: " A mountain 雪\n", model: "image-01", timeout_ms: 5_000}
  defp config(base_url), do: %{api_key: "minimax-image-fixture", base_url: base_url}

  defp body,
    do: %{
      "model" => "image-01",
      "prompt" => " A mountain 雪\n",
      "response_format" => "base64",
      "n" => 1
    }

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> MiniMax.generate(request, config) end)
    |> Task.await(10_000)
  end
end
