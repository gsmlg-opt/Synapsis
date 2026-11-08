defmodule Synapsis.Provider.VideoGeneration.XAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.VideoGeneration.XAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/xai-video-generation.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builds source defaults with exact Unicode prompt and explicit host budgets" do
    assert {:ok, built} = XAI.build_request(request(), config())

    assert built == %{
             url: "https://api.x.ai/v1/videos/generations",
             model: "grok-imagine-video",
             mode: "generate",
             timeout_ms: 4_321,
             max_video_bytes: 16_777_216,
             max_response_bytes: 1_048_576,
             body: %{
               "model" => "grok-imagine-video",
               "prompt" => "  雪の街 🎥\n",
               "duration" => 8,
               "aspect_ratio" => "16:9",
               "resolution" => "480p"
             }
           }
  end

  test "preserves a trimmed explicit model and supported geometry without inventing fields" do
    req =
      Map.merge(request(), %{
        model: " custom-video ",
        duration_seconds: 6.5,
        aspect_ratio: " 9:16 ",
        resolution: " 1080P ",
        size: "1920x1080",
        audio: true,
        watermark: false,
        provider_options: %{xai: %{seed: 23}}
      })

    assert {:ok, built} =
             XAI.build_request(
               req,
               Map.merge(config(), %{
                 base_url: " https://video.example/v2/// ",
                 max_video_bytes: 99,
                 max_response_bytes: 111
               })
             )

    assert built.url == "https://video.example/v2/videos/generations"
    assert built.model == "custom-video"
    assert built.max_video_bytes == 99
    assert built.max_response_bytes == 111

    assert built.body == %{
             "model" => "custom-video",
             "prompt" => request().prompt,
             "duration" => 7,
             "aspect_ratio" => "9:16",
             "resolution" => "720p"
           }
  end

  test "single first-frame URL takes precedence over bytes and inherits the frame ratio" do
    for role <- [nil, " First_Frame "] do
      image = %{url: " https://images.example/雪.png ", data: <<0, 255>>, role: role}

      assert {:ok, built} =
               XAI.build_request(Map.put(request(), :input_images, [image]), config())

      assert built.mode == "generate"

      assert built.body == %{
               "model" => "grok-imagine-video",
               "prompt" => request().prompt,
               "image" => %{"url" => "https://images.example/雪.png"},
               "duration" => 8,
               "resolution" => "480p"
             }
    end
  end

  test "already-read image bytes become source data URLs with trimmed or default MIME" do
    for {mime, expected} <- [{nil, "image/png"}, {" image/webp ", "image/webp"}] do
      req =
        Map.merge(request(), %{
          input_images: [%{data: <<0, 255, 128>>, mime_type: mime}],
          aspect_ratio: " 4:3 "
        })

      assert {:ok, built} = XAI.build_request(req, config())

      assert built.body == %{
               "model" => "grok-imagine-video",
               "prompt" => request().prompt,
               "image" => %{"url" => "data:#{expected};base64,AP+A"},
               "duration" => 8,
               "aspect_ratio" => "4:3",
               "resolution" => "480p"
             }
    end
  end

  test "seven reference images retain input order and the reference duration bound" do
    images =
      for index <- 1..7,
          do: %{url: " https://images.example/#{index}.png ", role: " ReFeReNcE_ImAgE "}

    req =
      Map.merge(request(), %{input_images: images, duration_seconds: 14.6, resolution: "1080p"})

    assert {:ok, built} = XAI.build_request(req, config())

    assert built.mode == "referenceToVideo"

    assert built.body == %{
             "model" => "grok-imagine-video",
             "prompt" => request().prompt,
             "reference_images" =>
               Enum.map(1..7, &%{"url" => "https://images.example/#{&1}.png"}),
             "duration" => 10,
             "aspect_ratio" => "16:9",
             "resolution" => "720p"
           }
  end

  test "remote video edits omit duration and generation geometry" do
    req =
      Map.merge(request(), %{
        input_videos: [%{url: " https://video.example/input.mp4 "}],
        aspect_ratio: "9:16",
        resolution: "720p"
      })

    assert {:ok, built} = XAI.build_request(req, config())
    assert built.url == "https://api.x.ai/v1/videos/edits"
    assert built.mode == "edit"

    assert built.body == %{
             "model" => "grok-imagine-video",
             "prompt" => request().prompt,
             "video" => %{"url" => "https://video.example/input.mp4"}
           }
  end

  test "durations round before source mode-specific clamps including extension minimum" do
    for {duration, expected} <- [{0.5, 1}, {1.5, 2}, {14.5, 15}, {24, 15}] do
      assert {:ok, built} =
               XAI.build_request(Map.put(request(), :duration_seconds, duration), config())

      assert built.body["duration"] == expected
    end

    for {duration, expected} <- [{0.5, 2}, {2.5, 3}, {9.5, 10}, {20, 10}] do
      req =
        Map.merge(request(), %{
          input_videos: [%{url: "https://video.example/input.mp4"}],
          duration_seconds: duration
        })

      assert {:ok, built} = XAI.build_request(req, config())
      assert built.url == "https://api.x.ai/v1/videos/extensions"
      assert built.mode == "extend"

      assert built.body == %{
               "model" => "grok-imagine-video",
               "prompt" => request().prompt,
               "video" => %{"url" => "https://video.example/input.mp4"},
               "duration" => expected
             }
    end
  end

  test "canonical and preview or dated 1.5 identifiers preserve single-frame 1080p" do
    for model <- [
          "grok-imagine-video-1.5",
          "grok-imagine-video-1.5-preview",
          "grok-imagine-video-1.5-2026-05-30"
        ],
        role <- [nil, " FIRST_FRAME "] do
      req =
        Map.merge(request(), %{
          model: " #{model} ",
          input_images: [%{data: "frame", role: role}],
          resolution: " 1080P "
        })

      assert {:ok, built} = XAI.build_request(req, config())
      assert built.model == model

      assert built.body == %{
               "model" => model,
               "prompt" => request().prompt,
               "image" => %{"url" => "data:image/png;base64,ZnJhbWU="},
               "duration" => 8,
               "resolution" => "1080p"
             }
    end
  end

  test "actual create status and byte download preserve exact bodies and metadata for every mode",
       %{fixture: fixture, tasks: tasks} do
    vectors = [
      {"generate", %{}, "generations",
       %{"duration" => 8, "aspect_ratio" => "16:9", "resolution" => "480p"}, nil, "video/mp4",
       "mp4"},
      {"referenceToVideo", %{input_images: [%{data: "ref", role: "reference_image"}]},
       "generations",
       %{
         "reference_images" => [%{"url" => "data:image/png;base64,cmVm"}],
         "duration" => 8,
         "aspect_ratio" => "16:9",
         "resolution" => "480p"
       }, " video/webm; codecs=vp9 ", "video/webm; codecs=vp9", "webm"},
      {"edit", %{input_videos: [%{url: "https://source.example/original.mp4"}]}, "edits",
       %{"video" => %{"url" => "https://source.example/original.mp4"}}, "video/quicktime",
       "video/quicktime", "mov"},
      {"extend",
       %{input_videos: [%{url: "https://source.example/original.mp4"}], duration_seconds: 4.5},
       "extensions",
       %{"video" => %{"url" => "https://source.example/original.mp4"}, "duration" => 5},
       "video/x-matroska", "video/x-matroska", "mkv"}
    ]

    owner = self()

    for {mode, overrides, endpoint, fields, header, mime, extension} <- vectors do
      prefix = "/#{mode}"
      video_url = Gaoxy.Test.url(fixture, prefix <> "/asset")

      expected =
        Map.merge(%{"model" => "grok-imagine-video", "prompt" => request().prompt}, fields)

      bytes = <<0, 255, 128, 1, 2, 3>>

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/videos/" <> endpoint, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == expected
        [key] = Plug.Conn.get_req_header(conn, "x-idempotency-key")
        assert key =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        send(owner, {:step, mode, :post, key})
        json(conn, %{"request_id" => " job-#{mode} "})
      end)

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/videos/job-" <> mode, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-idempotency-key") == []
        send(owner, {:step, mode, :status})
        json(conn, %{"status" => " DoNe ", "video" => %{"url" => " #{video_url} "}})
      end)

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/asset", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-idempotency-key") == []
        send(owner, {:step, mode, :download})
        conn = if header, do: Plug.Conn.put_resp_header(conn, "content-type", header), else: conn
        Plug.Conn.resp(conn, 200, bytes)
      end)

      assert {:ok, result} =
               generate(tasks, Map.merge(request(), overrides), local_config(fixture, prefix))

      assert result == %{
               model: "grok-imagine-video",
               videos: [%{data: bytes, mime_type: mime, filename: "video-1.#{extension}"}],
               metadata: %{
                 request_id: "job-#{mode}",
                 status: "DoNe",
                 video_url: video_url,
                 mode: mode
               }
             }

      assert_receive {:step, ^mode, :post, key}, 1_000
      assert_receive {:step, ^mode, :status}, 1_000
      assert_receive {:step, ^mode, :download}, 1_000
      send(self(), {:submit_key, key})
    end

    keys =
      for _ <- vectors do
        assert_receive {:submit_key, key}
        key
      end

    assert length(Enum.uniq(keys)) == length(vectors)
    Gaoxy.Test.verify!(fixture)
  end

  @tag timeout: 25_000
  test "pending then processing waits twice before mixed-case done and download", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    counter = :atomics.new(1, [])
    video_url = Gaoxy.Test.url(fixture, "/poll/asset")

    Gaoxy.Test.expect_once(fixture, "POST", "/poll/videos/generations", fn conn ->
      send(owner, {:poll_step, :post, System.monotonic_time(:millisecond)})
      json(conn, %{"request_id" => "poll-job"})
    end)

    Gaoxy.Test.expect(
      fixture,
      "GET",
      "/poll/videos/poll-job",
      fn conn ->
        index = :atomics.add_get(counter, 1, 1)
        status = Enum.at(["pending", "processing", "dOnE"], index - 1)
        send(owner, {:poll_step, status, System.monotonic_time(:millisecond)})
        json(conn, %{"status" => status, "video" => %{"url" => video_url}})
      end,
      times: 3
    )

    Gaoxy.Test.expect_once(fixture, "GET", "/poll/asset", fn conn ->
      send(owner, {:poll_step, :download, System.monotonic_time(:millisecond)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "video/mp4")
      |> Plug.Conn.resp(200, "video")
    end)

    assert {:ok, result} =
             generate(
               tasks,
               Map.put(request(), :timeout_ms, 20_000),
               local_config(fixture, "/poll")
             )

    assert result.metadata.status == "dOnE"
    assert result.videos == [%{data: "video", mime_type: "video/mp4", filename: "video-1.mp4"}]
    assert_receive {:poll_step, :post, submitted}
    assert_receive {:poll_step, "pending", first}
    assert_receive {:poll_step, "processing", second}
    assert_receive {:poll_step, "dOnE", third}
    assert_receive {:poll_step, :download, downloaded}
    assert first - submitted < 4_000
    assert second - first >= 5_000
    assert third - second >= 5_000
    assert downloaded >= third
    Gaoxy.Test.verify!(fixture)
  end

  test "chunked raw JSON and opaque video succeed exactly at their configured byte caps", %{
    fixture: fixture,
    tasks: tasks
  } do
    video_url = Gaoxy.Test.url(fixture, "/caps/asset")
    submitted = Jason.encode!(%{"request_id" => "caps-job"})
    completed = Jason.encode!(%{"status" => "done", "video" => %{"url" => video_url}})
    bytes = <<0, 255, 128, 9, 7, 0, 255>>

    Gaoxy.Test.expect_once(fixture, "POST", "/caps/videos/generations", fn conn ->
      chunked(conn, submitted, "application/json")
    end)

    Gaoxy.Test.expect_once(fixture, "GET", "/caps/videos/caps-job", fn conn ->
      chunked(conn, completed, "application/json")
    end)

    Gaoxy.Test.expect_once(fixture, "GET", "/caps/asset", fn conn ->
      chunked(conn, bytes, "video/mp4")
    end)

    cfg =
      Map.merge(local_config(fixture, "/caps"), %{
        max_response_bytes: max(byte_size(submitted), byte_size(completed)),
        max_video_bytes: byte_size(bytes)
      })

    assert {:ok, result} = generate(tasks, request(), cfg)
    assert result.videos == [%{data: bytes, mime_type: "video/mp4", filename: "video-1.mp4"}]
    Gaoxy.Test.verify!(fixture)
  end

  test "different ordinary total budgets share Req.Finch across all three HTTP steps", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()
    port = URI.parse(Gaoxy.Test.url(fixture)).port
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:finch, :request, :start], &__MODULE__.capture_pool_start/4, %{
        owner: owner,
        port: port
      })

    on_exit(fn -> :telemetry.detach(handler) end)

    for timeout <- [1_001, 2_002, 3_003] do
      prefix = "/pool/#{timeout}"
      video_url = Gaoxy.Test.url(fixture, prefix <> "/asset")

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/videos/generations", fn conn ->
        json(conn, %{"request_id" => "pool-job"})
      end)

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/videos/pool-job", fn conn ->
        json(conn, %{"status" => "done", "video" => %{"url" => video_url}})
      end)

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/asset", fn conn ->
        Plug.Conn.resp(conn, 200, "pool-video")
      end)

      assert {:ok, result} =
               generate(
                 tasks,
                 Map.put(request(), :timeout_ms, timeout),
                 local_config(fixture, prefix)
               )

      assert hd(result.videos).data == "pool-video"
    end

    names =
      for _ <- 1..9 do
        assert_receive {:video_pool_started, name}, 1_000
        name
      end

    assert names == List.duplicate(Req.Finch, 9)
    Gaoxy.Test.verify!(fixture)
  end

  test "all comparable pinned source rows retain their complete initial request plans" do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(capture["observations"]) == 34
    rows = Enum.filter(capture["observations"], & &1["hostComparable"])
    assert length(rows) == 33

    for row <- rows do
      submitted = Enum.find(row["requests"], &(&1["stage"] == "submit"))
      binary_reader = Enum.find(row["readerCalls"], &(&1["kind"] == "binary"))

      assert {:ok, built} =
               XAI.build_request(reference_request(row["input"]), reference_config(row["config"]))

      assert built == %{
               url: submitted["url"],
               model: row["result"]["model"],
               mode: row["result"]["metadata"]["mode"],
               timeout_ms: row["input"]["timeoutMs"],
               max_video_bytes: binary_reader["maxBytes"],
               max_response_bytes: 1_048_576,
               body: submitted["jsonBody"]
             },
             row["id"]
    end
  end

  @tag timeout: 45_000
  test "all comparable source rows replay exact HTTP fields status order and complete video results",
       %{fixture: fixture, tasks: tasks} do
    rows =
      @reference
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("observations")
      |> Enum.filter(& &1["hostComparable"])

    owner = self()

    for row <- rows do
      id = row["id"]
      prefix = "/reference/" <> id
      submitted = Enum.find(row["requests"], &(&1["stage"] == "submit"))
      poll = Enum.find(row["requests"], &(&1["stage"] == "poll"))
      video_url = Gaoxy.Test.url(fixture, prefix <> "/asset")
      polls = row["response"]["polls"]
      counter = :atomics.new(1, [])

      Gaoxy.Test.expect_once(
        fixture,
        "POST",
        prefix <> URI.parse(submitted["url"]).path,
        fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(raw) == submitted["jsonBody"], id
          [key] = Plug.Conn.get_req_header(conn, "x-idempotency-key")
          assert key =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
          send(owner, {:reference_step, id, "submit"})
          json(conn, row["response"]["submit"])
        end
      )

      Gaoxy.Test.expect(
        fixture,
        "GET",
        prefix <> URI.parse(poll["url"]).path,
        fn conn ->
          index = :atomics.add_get(counter, 1, 1)
          payload = Enum.at(polls, index - 1)
          assert Plug.Conn.get_req_header(conn, "x-idempotency-key") == []
          send(owner, {:reference_step, id, "poll"})

          payload =
            if is_map(payload["video"]),
              do: put_in(payload, ["video", "url"], video_url),
              else: payload

          json(conn, payload)
        end,
        times: length(polls)
      )

      download = row["response"]["download"]

      Gaoxy.Test.expect_once(fixture, "GET", prefix <> "/asset", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-idempotency-key") == []
        send(owner, {:reference_step, id, "download"})

        conn =
          if download["contentType"],
            do: Plug.Conn.put_resp_header(conn, "content-type", download["contentType"]),
            else: conn

        Plug.Conn.resp(conn, 200, Base.decode64!(download["bytesBase64"]))
      end)

      cfg = reference_config(row["config"])

      base_path =
        cfg.base_url
        |> String.trim()
        |> String.trim_trailing("/")
        |> URI.parse()
        |> Map.fetch!(:path)

      cfg = Map.put(cfg, :base_url, Gaoxy.Test.url(fixture, prefix <> base_path))
      assert {:ok, result} = generate(tasks, reference_request(row["input"]), cfg)
      assert result == reference_result(row["result"], video_url), id

      steps =
        for _ <- row["requests"] do
          assert_receive {:reference_step, ^id, stage}, 1_000
          stage
        end

      assert steps == Enum.map(row["requests"], & &1["stage"]), id
    end

    Gaoxy.Test.verify!(fixture)
  end

  defp reference_request(input) do
    fields = [
      {"model", :model},
      {"prompt", :prompt},
      {"timeoutMs", :timeout_ms},
      {"durationSeconds", :duration_seconds},
      {"aspectRatio", :aspect_ratio},
      {"resolution", :resolution}
    ]

    request =
      Enum.reduce(fields, %{}, fn {key, atom}, acc ->
        if Map.has_key?(input, key), do: Map.put(acc, atom, input[key]), else: acc
      end)

    Enum.reduce(
      [{"inputImages", :input_images}, {"inputVideos", :input_videos}],
      request,
      fn {key, atom}, acc ->
        if Map.has_key?(input, key),
          do: Map.put(acc, atom, Enum.map(input[key], &reference_asset/1)),
          else: acc
      end
    )
  end

  defp reference_asset(input) do
    asset =
      Enum.reduce([{"url", :url}, {"mimeType", :mime_type}, {"role", :role}], %{}, fn {key, atom},
                                                                                      acc ->
        if Map.has_key?(input, key), do: Map.put(acc, atom, input[key]), else: acc
      end)

    if input["bytesBase64"],
      do: Map.put(asset, :data, Base.decode64!(input["bytesBase64"])),
      else: asset
  end

  defp reference_config(input) do
    cfg = Map.put(config(), :base_url, input["baseUrl"])

    if input["mediaMaxMb"],
      do: Map.put(cfg, :max_video_bytes, floor(input["mediaMaxMb"] * 1024 * 1024)),
      else: cfg
  end

  defp reference_result(result, video_url) do
    metadata = result["metadata"]

    %{
      videos:
        Enum.map(result["videos"], fn video ->
          %{
            data: Base.decode64!(video["bytesBase64"]),
            mime_type: video["mimeType"],
            filename: video["fileName"]
          }
        end),
      model: result["model"],
      metadata: %{
        request_id: metadata["requestId"],
        status: metadata["status"],
        video_url: video_url,
        mode: metadata["mode"]
      }
    }
  end

  def capture_pool_start(_event, _measurements, metadata, %{owner: owner, port: port}) do
    case metadata do
      %{name: name, request: %{port: ^port}} -> send(owner, {:video_pool_started, name})
      _ -> :ok
    end
  end

  defp request, do: %{prompt: "  雪の街 🎥\n", timeout_ms: 4_321}
  defp config, do: %{api_key: "video-fixture"}

  defp local_config(fixture, prefix),
    do: Map.put(config(), :base_url, Gaoxy.Test.url(fixture, prefix))

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> XAI.generate(request, config) end)
    |> Task.await(22_000)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp chunked(conn, bytes, mime) do
    conn = conn |> Plug.Conn.put_resp_header("content-type", mime) |> Plug.Conn.send_chunked(200)
    <<first, rest::binary>> = bytes
    {:ok, conn} = Plug.Conn.chunk(conn, <<first>>)
    {:ok, conn} = Plug.Conn.chunk(conn, rest)
    conn
  end
end
