defmodule Synapsis.Provider.ImageGeneration.VydraFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.ImageGeneration.Vydra

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/vydra-image-generation.json",
               __DIR__
             )
  @external_resource @reference

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3E//Z"
        )
  @webp Base.decode64!("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "explicit builder preserves prompt bytes and source base and model normalization" do
    request = %{prompt: "  light 雪\n", model: "\uFEFF grok-imagine \u00A0", timeout_ms: 5_000.75}

    for {base, expected} <- [
          {" https://vydra.ai/// ", "https://www.vydra.ai/api/v1/models/grok-imagine"},
          {"https://images.example/custom///",
           "https://images.example/custom/models/grok-imagine"},
          {"https://images.example", "https://images.example/api/v1/models/grok-imagine"}
        ] do
      assert {:ok, built} = Vydra.build_request(request, config(base))
      assert built.url == expected
      assert built.model == "grok-imagine"
      assert built.body == %{"prompt" => "  light 雪\n", "model" => "text-to-image"}
      assert built.timeout_ms == 5_000
      assert built.max_response_bytes == 16_777_216
      assert built.max_image_bytes == 67_108_864
    end

    assert {:ok, built} =
             Vydra.build_request(
               request,
               Map.put(config("https://images.example"), :max_image_bytes, 83_886_080)
             )

    assert built.max_image_bytes == 83_886_080
  end

  test "immediate URL result returns exact image bytes and trimmed metadata", ctx do
    url = Gaoxy.Test.url(ctx.fixture, "/images/immediate.png")
    owner = self()

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/relay/models/grok-imagine", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"prompt" => "  cat 猫\n", "model" => "text-to-image"}
      send(owner, :submitted)

      json(conn, %{"id" => " ordinary-id ", "status" => " Completed ", "imageUrl" => " #{url} "})
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/images/immediate.png", fn conn ->
      send(owner, :downloaded)
      image(conn, @png, "image/png")
    end)

    request = %{prompt: "  cat 猫\n", model: " grok-imagine ", timeout_ms: 5_000}

    assert {:ok, result} =
             generate(ctx, request, config(Gaoxy.Test.url(ctx.fixture, "/relay///")))

    assert result == %{
             model: "grok-imagine",
             metadata: %{job_id: "ordinary-id", image_url: url, status: "completed"},
             images: [%{data: @png, mime_type: "image/png", filename: "image-1.png"}]
           }

    assert_receive :submitted
    assert_receive :downloaded
  end

  test "URL keys and recursive containers preserve the first source-ordered URL", ctx do
    cases =
      Enum.map(
        ~w(imageUrl imageUrls resultUrl resultUrls outputUrl outputUrls url urls),
        fn key ->
          {key, fn first, second -> %{key => [" #{first} ", [second, first]]} end}
        end
      ) ++
        Enum.map(~w(output outputs result results data asset assets), fn key ->
          {key, fn first, second -> %{key => [%{"imageUrls" => [[first, second]]}]} end}
        end) ++
        [
          {"key-order",
           fn first, second ->
             %{"url" => second, "resultUrl" => second, "imageUrl" => first}
           end},
          {"recursive-order",
           fn first, second ->
             %{"data" => %{"imageUrl" => second}, "output" => %{"imageUrl" => first}}
           end},
          {"depth-five",
           fn first, _second ->
             %{"output" => [%{"result" => %{"data" => %{"asset" => %{"url" => first}}}}]}
           end}
        ]

    for {id, payload} <- cases do
      prefix = "/ordered/#{id}"
      url = Gaoxy.Test.url(ctx.fixture, prefix <> "/first.png")
      second = Gaoxy.Test.url(ctx.fixture, prefix <> "/second.png")

      Gaoxy.Test.expect_once(ctx.fixture, "POST", prefix <> "/models/grok-imagine", fn conn ->
        json(conn, payload.(url, second))
      end)

      Gaoxy.Test.expect_once(ctx.fixture, "GET", prefix <> "/first.png", fn conn ->
        image(conn, @png, "image/png")
      end)

      assert {:ok, result} = generate(ctx, request(), config(Gaoxy.Test.url(ctx.fixture, prefix)))

      assert result == %{
               model: "grok-imagine",
               metadata: %{image_url: url, status: "completed"},
               images: [%{data: @png, mime_type: "image/png", filename: "image-1.png"}]
             }
    end
  end

  test "queued submission polls immediately, waits between pending reads and prefers completed id",
       ctx do
    owner = self()
    url = Gaoxy.Test.url(ctx.fixture, "/images/polled.png")
    polls = :atomics.new(1, [])

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/api/v1/models/grok-imagine", fn conn ->
      send(owner, {:submitted_at, System.monotonic_time(:millisecond)})

      json(conn, %{
        "jobId" => " submit-primary ",
        "id" => "submit-secondary",
        "status" => " QUEUED "
      })
    end)

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/api/v1/jobs/submit-primary",
      fn conn ->
        index = :atomics.add_get(polls, 1, 1)
        send(owner, {:polled_at, index, System.monotonic_time(:millisecond)})

        case index do
          1 -> json(conn, %{"status" => "processing"})
          2 -> json(conn, %{"id" => " final-id ", "status" => " COMPLETED ", "imageUrl" => url})
        end
      end,
      times: 2
    )

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/images/polled.png", fn conn ->
      image(conn, @png, "image/png")
    end)

    assert {:ok, result} = generate(ctx, request(), config(Gaoxy.Test.url(ctx.fixture)))

    assert result == %{
             model: "grok-imagine",
             metadata: %{job_id: "final-id", image_url: url, status: "completed"},
             images: [%{data: @png, mime_type: "image/png", filename: "image-1.png"}]
           }

    assert_receive {:submitted_at, submitted_at}
    assert_receive {:polled_at, 1, first_poll_at}
    assert_receive {:polled_at, 2, second_poll_at}
    assert first_poll_at - submitted_at < 2_500
    assert second_poll_at - first_poll_at >= 2_500
    assert :atomics.get(polls, 1) == 2
  end

  test "ordinary PNG, JPEG and WebP preserve MIME parameters, filename extension and default PNG",
       ctx do
    for {id, bytes, mime, expected_mime, filename} <- [
          {"png", @png, " Image/PNG; charset=binary ", "Image/PNG; charset=binary",
           "image-1.png"},
          {"jpeg", @jpeg, "image/jpeg", "image/jpeg", "image-1.jpg"},
          {"webp", @webp, "image/webp", "image/webp", "image-1.webp"},
          {"missing", @png, nil, "image/png", "image-1.png"}
        ] do
      prefix = "/mime/#{id}"
      url = Gaoxy.Test.url(ctx.fixture, prefix <> "/provider-name.bin")

      Gaoxy.Test.expect_once(ctx.fixture, "POST", prefix <> "/models/grok-imagine", fn conn ->
        json(conn, %{"imageUrl" => url})
      end)

      Gaoxy.Test.expect_once(ctx.fixture, "GET", prefix <> "/provider-name.bin", fn conn ->
        image(conn, bytes, mime)
      end)

      assert {:ok, result} = generate(ctx, request(), config(Gaoxy.Test.url(ctx.fixture, prefix)))

      assert result == %{
               model: "grok-imagine",
               metadata: %{image_url: url, status: "completed"},
               images: [%{data: bytes, mime_type: expected_mime, filename: filename}]
             }
    end
  end

  test "ordinary callback options leave the fixed body unchanged and URL-bearing status survives",
       ctx do
    url = Gaoxy.Test.url(ctx.fixture, "/images/options.png")

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/api/v1/models/grok-imagine", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"prompt" => "ordinary", "model" => "text-to-image"}
      assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]
      json(conn, %{"status" => " Queued ", "imageUrl" => url})
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/images/options.png", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]
      image(conn, @png, "image/png")
    end)

    request =
      Map.merge(request(), %{
        count: 1,
        input_images: [],
        size: "1024x1024",
        aspect_ratio: "16:9",
        resolution: "2K",
        quality: "high",
        output_format: "webp",
        background: "transparent",
        provider_options: %{"vydra" => %{"style" => "ordinary"}}
      })

    cfg = config(Gaoxy.Test.url(ctx.fixture)) |> Map.put(:headers, %{"X-Context" => " ordinary "})
    assert {:ok, result} = generate(ctx, request, cfg)

    assert result == %{
             model: "grok-imagine",
             metadata: %{image_url: url, status: "queued"},
             images: [%{data: @png, mime_type: "image/png", filename: "image-1.png"}]
           }
  end

  test "the linked HTTP owner exits normally after an ordinary successful result", ctx do
    owner = self()
    url = Gaoxy.Test.url(ctx.fixture, "/images/owner.png")

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/api/v1/models/grok-imagine", fn conn ->
      send(owner, {:http_waiting, self()})

      receive do
        :respond -> :ok
      after
        2_000 -> flunk("ordinary response was not released")
      end

      json(conn, %{"imageUrl" => url})
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/images/owner.png", fn conn ->
      image(conn, @png, "image/png")
    end)

    caller =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        Vydra.generate(request(), config(Gaoxy.Test.url(ctx.fixture)))
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, &(is_pid(&1) and &1 != ctx.tasks))
    monitor = Process.monitor(http_owner)
    send(handler, :respond)

    assert {:ok, result} = Task.await(caller, 5_000)
    assert result.images == [%{data: @png, mime_type: "image/png", filename: "image-1.png"}]
    assert_receive {:DOWN, ^monitor, :process, ^http_owner, :normal}, 2_000
  end

  test "all 41 explicit source rows match complete builders, actual HTTP sequence and full results",
       ctx do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert length(rows) == 46
    assert length(Enum.uniq_by(rows, & &1["id"])) == 46

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-omitted-model",
             "source-only-omitted-timeout",
             "source-only-omitted-base",
             "source-only-canonical-base",
             "source-only-configured-header"
           ]

    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 41

    # Every complete production-URL builder is compared before transport changes.
    prepared =
      for row <- comparable do
        id = row["id"]
        request = reference_request(row["input"])
        config = reference_config(row)
        post = hd(row["requests"])
        download = List.last(row["requests"])
        assert {:ok, built} = Vydra.build_request(request, config)

        assert built == %{
                 url: post["url"],
                 base_url: hd(row["configCalls"])["output"]["baseUrl"],
                 model: row["result"]["model"],
                 body: post["body"],
                 headers: post["headers"],
                 timeout_ms: min(2_147_000_000, max(1, floor(row["input"]["timeoutMs"]))),
                 max_response_bytes: post["maxBytes"],
                 max_image_bytes: download["maxBytes"]
               },
               id

        assert Jason.decode!(post["rawBody"]) == built.body, id
        assert row["inputAfter"] == row["input"], id
        assert row["configAfter"] == row["config"], id
        assert_source_stages(row, built)
        {row, request, config}
      end

    for {row, request, config} <- prepared do
      id = row["id"]
      fixture = Gaoxy.Test.open()
      previous = Req.default_options()
      on_exit(fn -> Req.default_options(previous) end)

      try do
        route_reference_requests(fixture, row, previous)
        expect_reference_requests(fixture, row)
        assert {:ok, result} = generate(ctx, request, config), id
        assert result == reference_result(row["result"]), id

        original_sequence =
          for _ <- row["requests"] do
            assert_receive {:source_request, ^id, method, url}, 2_000
            {method, url}
          end

        assert original_sequence == Enum.map(row["requests"], &{&1["method"], &1["url"]}), id

        wire_sequence =
          for _ <- row["requests"] do
            assert_receive {:wire_request, ^id, method, path, query, body}, 2_000
            {method, path, query, body}
          end

        assert wire_sequence ==
                 Enum.map(row["requests"], fn expected ->
                   uri = URI.parse(expected["url"])
                   {expected["method"], uri.path, uri.query || "", expected["body"]}
                 end),
               id

        Gaoxy.Test.verify_and_close!(fixture)
      after
        Req.default_options(previous)
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp reference_request(input) do
    keys = %{
      "prompt" => :prompt,
      "model" => :model,
      "timeoutMs" => :timeout_ms,
      "count" => :count,
      "inputImages" => :input_images,
      "size" => :size,
      "aspectRatio" => :aspect_ratio,
      "resolution" => :resolution,
      "quality" => :quality,
      "outputFormat" => :output_format,
      "background" => :background,
      "providerOptions" => :provider_options
    }

    for {source, target} <- keys,
        Map.has_key?(input, source),
        into: %{},
        do: {target, input[source]}
  end

  defp reference_config(row) do
    config = %{api_key: "synthetic-explicit-key", base_url: row["config"]["baseUrl"]}

    if Map.has_key?(row, "mediaMaxMb"),
      do: Map.put(config, :max_image_bytes, floor(row["mediaMaxMb"] * 1024 * 1024)),
      else: config
  end

  defp reference_result(result) do
    metadata = %{
      image_url: result["metadata"]["imageUrl"],
      status: result["metadata"]["status"]
    }

    metadata =
      if Map.has_key?(result["metadata"], "jobId"),
        do: Map.put(metadata, :job_id, result["metadata"]["jobId"]),
        else: metadata

    %{
      model: result["model"],
      metadata: metadata,
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

  defp assert_source_stages(row, built) do
    id = row["id"]
    [post | later] = row["requests"]
    download = List.last(later)
    polls = Enum.filter(later, &(&1["kind"] == "poll"))
    assert post["kind"] == "post", id
    # This records the raw guarded-fetch argument; the host builder floors timers.
    assert post["timeoutMs"] == row["input"]["timeoutMs"], id
    assert download["kind"] == "download", id
    assert download["timeoutMs"] == built.timeout_ms, id
    assert download["url"] == hd(row["extractedUrls"]), id
    assert length(polls) == length(row["response"]["polls"]), id

    if polls != [] do
      assert hd(polls)["atMs"] == post["releasedAtMs"], id
    end

    expected_events =
      row["requests"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {request, index} ->
        previous = if index > 0, do: Enum.at(row["requests"], index - 1)

        wait =
          if request["kind"] == "poll" and previous["kind"] == "poll" do
            assert request["atMs"] - previous["releasedAtMs"] == 2_500, id

            [
              %{
                "kind" => "wait",
                "durationMs" => 2_500,
                "atMs" => previous["releasedAtMs"],
                "implementation" => "synthetic-wait-facade"
              }
            ]
          else
            []
          end

        assert request["releaseCount"] == 1, id
        assert request["releasedAtMs"] > request["atMs"], id

        wait ++
          [
            %{
              "kind" => "request",
              "stage" => request["kind"],
              "url" => request["url"],
              "atMs" => request["atMs"]
            },
            %{
              "kind" => "release",
              "stage" => request["kind"],
              "url" => request["url"],
              "atMs" => request["releasedAtMs"]
            }
          ]
      end)

    assert row["events"] == expected_events, id

    for {request, reader} <- Enum.zip(row["requests"], row["readerCalls"]) do
      assert reader["kind"] == request["kind"], id
      assert reader["maxBytes"] == request["maxBytes"], id
      assert reader["bytesRead"] == Enum.sum(reader["chunkLengths"]), id

      case request["kind"] do
        "post" ->
          assert reader["timeoutMs"] == nil, id
          assert reader["chunkTimeoutMs"] == 30_000, id

        "poll" ->
          deadline = post["releasedAtMs"] + built.timeout_ms
          assert request["timeoutMs"] == min(120_000, deadline - request["atMs"]), id
          assert reader["timeoutMs"] == min(120_000, deadline - reader["atMs"]), id
          assert reader["chunkTimeoutMs"] == 30_000, id

        "download" ->
          deadline = request["atMs"] + built.timeout_ms
          assert reader["timeoutMs"] == deadline - reader["atMs"], id
          assert reader["chunkTimeoutMs"] == 0, id
      end
    end
  end

  defp route_reference_requests(fixture, row, previous) do
    owner = self()
    index = :atomics.new(1, [])
    address = URI.parse(Gaoxy.Test.url(fixture))

    plugin = fn request ->
      Req.Request.prepend_request_steps(request,
        vydra_fixture: fn request ->
          expected = Enum.fetch!(row["requests"], :atomics.add_get(index, 1, 1) - 1)
          original_url = URI.to_string(request.url)
          method = request.method |> Atom.to_string() |> String.upcase()
          assert original_url == expected["url"], row["id"]
          assert method == expected["method"], row["id"]
          send(owner, {:source_request, row["id"], method, original_url})

          %{
            request
            | url: %{request.url | scheme: address.scheme, host: address.host, port: address.port}
          }
        end
      )
    end

    Req.default_options(
      Keyword.put(previous, :plugins, [plugin | Keyword.get(previous, :plugins, [])])
    )
  end

  defp expect_reference_requests(fixture, row) do
    owner = self()

    row["requests"]
    |> Enum.with_index()
    |> Enum.group_by(fn {request, _index} ->
      {request["method"], URI.parse(request["url"]).path}
    end)
    |> Enum.each(fn {{method, path}, requests} ->
      counter = :atomics.new(1, [])

      Gaoxy.Test.expect(
        fixture,
        method,
        path,
        fn conn ->
          {expected, index} = Enum.fetch!(requests, :atomics.add_get(counter, 1, 1) - 1)
          assert conn.query_string == (URI.parse(expected["url"]).query || ""), row["id"]

          for {name, value} <- expected["headers"] do
            assert Plug.Conn.get_req_header(conn, name) == [value], row["id"]
          end

          {body, conn} =
            if method == "POST" do
              {:ok, raw, conn} = Plug.Conn.read_body(conn)
              actual = Jason.decode!(raw)
              assert actual == expected["body"], row["id"]
              {actual, conn}
            else
              {nil, conn}
            end

          send(
            owner,
            {:wire_request, row["id"], conn.method, conn.request_path, conn.query_string, body}
          )

          case expected["kind"] do
            "post" -> json(conn, row["response"]["submitted"])
            "poll" -> json(conn, Enum.fetch!(row["response"]["polls"], index - 1))
            "download" -> reference_image(conn, row["response"]["asset"])
          end
        end,
        times: length(requests)
      )
    end)
  end

  defp reference_image(conn, asset) do
    bytes = Base.decode64!(asset["bytesBase64"])

    if sizes = asset["chunkSizes"] do
      conn = Plug.Conn.put_resp_header(conn, "content-type", asset["mimeType"])
      conn = Plug.Conn.send_chunked(conn, 200)

      {conn, offset} =
        Enum.reduce(sizes, {conn, 0}, fn size, {conn, offset} ->
          {:ok, conn} = Plug.Conn.chunk(conn, binary_part(bytes, offset, size))
          {conn, offset + size}
        end)

      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(bytes, offset, byte_size(bytes) - offset))
      conn
    else
      image(conn, bytes, asset["mimeType"])
    end
  end

  defp request, do: %{prompt: "ordinary", model: "grok-imagine", timeout_ms: 5_000}
  defp config(base_url), do: %{api_key: "explicit-fixture-key", base_url: base_url}

  defp generate(ctx, request, config) do
    ctx.tasks
    |> Task.Supervisor.async_nolink(fn -> Vydra.generate(request, config) end)
    |> Task.await(10_000)
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  defp image(conn, bytes, mime) do
    conn = if mime, do: Plug.Conn.put_resp_header(conn, "content-type", mime), else: conn
    Plug.Conn.resp(conn, 200, bytes)
  end
end
