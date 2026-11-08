defmodule Synapsis.Provider.ImageGeneration.ComfyFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.Comfy

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/comfy-image-generation.json",
               __DIR__
             )

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "local pending history completes with exact prompt, history identity and trimmed model",
       ctx do
    owner = self()

    workflow = %{
      "6" => %{"inputs" => %{"text" => "baked", "untouched" => [1, 2]}},
      "9" => %{"inputs" => %{}}
    }

    request = %{prompt: "  light 雪\n", model: "\uFEFF custom label \u00A0", timeout_ms: 5_000}
    config = Map.put(config(ctx.fixture, workflow), :headers, %{"X-Context" => " ordinary "})

    assert {:ok, built} = Comfy.build_request(request, config)
    assert built.model == "custom label"
    assert built.timeout_ms == 5_000
    assert built.max_image_bytes == 67_108_864

    assert built.body == %{
             "prompt" => %{
               "6" => %{"inputs" => %{"text" => "  light 雪\n", "untouched" => [1, 2]}},
               "9" => %{"inputs" => %{}}
             }
           }

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "  light 雪\n", "untouched" => [1, 2]}},
                 "9" => %{"inputs" => %{}}
               }
             }

      assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]
      json(conn, ~s({"prompt_id":" p-local "}))
    end)

    polls = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/history/p-local",
      fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]

        case :atomics.add_get(polls, 1, 1) do
          1 ->
            send(owner, :pending_history)
            json(conn, "{}")

          2 ->
            send(owner, :completed_history)

            json(
              conn,
              ~s({"outputs":{"9":{"images":[{"name":" a b.png ","subfolder":" small set "}]}},"status":{"completed":true},"p-local":{"outputs":{"other":{"images":[{"filename":"unused.png"}]}}}})
            )
        end
      end,
      times: 2
    )

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/view", fn conn ->
      assert conn.query_string == "filename=a+b.png&subfolder=small+set&type=output"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "x-context") == ["ordinary"]
      image(conn, "image/png; charset=binary")
    end)

    assert {:ok, result} = generate(ctx, request, config)

    assert result == %{
             model: "custom label",
             metadata: %{prompt_id: "p-local", output_node_ids: ["9"]},
             images: [
               %{
                 data: @png,
                 mime_type: "image/png; charset=binary",
                 filename: "a b.png",
                 metadata: %{node_id: "9", prompt_id: "p-local"}
               }
             ]
           }

    assert_receive :pending_history
    assert_receive :completed_history
    assert workflow["6"]["inputs"]["text"] == "baked"
  end

  test "cloud polls running then completed and returns an ordinary two-image workflow without count",
       ctx do
    owner = self()

    cfg =
      config(ctx.fixture, workflow())
      |> Map.merge(%{mode: :cloud, api_key: "explicit-fixture-key"})

    req = %{prompt: "two small images", model: "workflow", timeout_ms: 5_000}

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/api/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "two small images"}},
                 "9" => %{"inputs" => %{}}
               },
               "extra_data" => %{"api_key_comfy_org" => "explicit-fixture-key"}
             }

      json(conn, ~s({"prompt_id":"cloud-one"}))
    end)

    polls = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/api/job/cloud-one/status",
      fn conn ->
        status = Enum.at(["running", "completed"], :atomics.add_get(polls, 1, 1) - 1)
        send(owner, {:status, status})
        json(conn, Jason.encode!(%{"status" => status}))
      end,
      times: 2
    )

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/api/history_v2/cloud-one", fn conn ->
      send(owner, :history_v2)

      json(
        conn,
        ~s({"cloud-one":{"outputs":{"9":{"images":[{"filename":"first.png"},{"filename":"second.png"}]}}}})
      )
    end)

    downloads = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/api/view",
      fn conn ->
        filename = Enum.at(["first.png", "second.png"], :atomics.add_get(downloads, 1, 1) - 1)
        assert conn.query_string == "filename=#{filename}&subfolder=&type=output"
        image(conn)
      end,
      times: 2
    )

    assert {:ok, result} = generate(ctx, req, cfg)

    assert result == %{
             model: "workflow",
             metadata: %{prompt_id: "cloud-one", output_node_ids: ["9"]},
             images: [
               %{
                 data: @png,
                 mime_type: "image/png",
                 filename: "first.png",
                 metadata: %{node_id: "9", prompt_id: "cloud-one"}
               },
               %{
                 data: @png,
                 mime_type: "image/png",
                 filename: "second.png",
                 metadata: %{node_id: "9", prompt_id: "cloud-one"}
               }
             ]
           }

    assert_receive {:status, "running"}
    assert_receive {:status, "completed"}
    assert_receive :history_v2
  end

  test "edit sends actual multipart image bytes and binds only the uploaded filename", ctx do
    graph = Map.put(workflow(), "7", %{"inputs" => %{"image" => "baked.png", "other" => true}})
    cfg = config(ctx.fixture, graph) |> Map.put(:input_image_node_id, "7")

    req = %{
      prompt: "edit",
      model: "workflow",
      timeout_ms: 5_000,
      input_images: [%{data: @png, mime_type: "Image/PNG", filename: "\uFEFF source.png \u00A0"}]
    }

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/upload/image", fn conn ->
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "multipart/form-data; boundary=")
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)

      assert {"content-disposition", ~s(form-data; name="image"; filename="source.png")} in headers

      assert {"content-type", "image/png"} in headers
      {:ok, bytes, conn} = Plug.Conn.read_part_body(conn, [])
      assert bytes == @png
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
      assert {"content-disposition", ~s(form-data; name="type")} in headers
      {:ok, "input", conn} = Plug.Conn.read_part_body(conn, [])
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
      assert {"content-disposition", ~s(form-data; name="overwrite")} in headers
      {:ok, "true", conn} = Plug.Conn.read_part_body(conn, [])
      {:done, conn} = Plug.Conn.read_part_headers(conn)
      json(conn, ~s({"filename":" uploaded.png ","name":"other.png","subfolder":"ignored"}))
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "edit"}},
                 "7" => %{"inputs" => %{"image" => "uploaded.png", "other" => true}},
                 "9" => %{"inputs" => %{}}
               }
             }

      json(conn, ~s({"prompt_id":"edited"}))
    end)

    successful_history(ctx.fixture, "edited", "edited.png")
    assert {:ok, %{images: [%{data: @png, filename: "edited.png"}]}} = generate(ctx, req, cfg)
    assert graph["7"]["inputs"]["image"] == "baked.png"
  end

  test "all image buckets retain JavaScript numeric and insertion node order and array order",
       ctx do
    owner = self()

    req = %{
      prompt: "ordered",
      model: "workflow",
      timeout_ms: 5_000,
      quality: "high",
      size: "1024x1024",
      output_format: "png",
      provider_options: %{"unused" => true}
    }

    expect_submit(ctx.fixture, "ordered", "ordered")

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/history/ordered", fn conn ->
      json(
        conn,
        ~s({"outputs":{"zeta":{"images":[{"filename":"z1.png"},{"filename":"z2.png"}]},"10":{"images":[{"filename":"ten.png"}]},"alpha":{"images":[{"filename":"a.png"}]},"2":{"images":[{"filename":"two.png"}]}}})
      )
    end)

    downloads = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/view",
      fn conn ->
        filename =
          Enum.at(
            ["two.png", "ten.png", "z1.png", "z2.png", "a.png"],
            :atomics.add_get(downloads, 1, 1) - 1
          )

        assert conn.query_string == "filename=#{filename}&subfolder=&type=output"
        send(owner, {:view, filename})
        image(conn)
      end,
      times: 5
    )

    assert {:ok, result} = generate(ctx, req, config(ctx.fixture, workflow()))

    assert Enum.map(result.images, &{&1.filename, &1.metadata.node_id, &1.data, &1.mime_type}) ==
             [
               {"two.png", "2", @png, "image/png"},
               {"ten.png", "10", @png, "image/png"},
               {"z1.png", "zeta", @png, "image/png"},
               {"z2.png", "zeta", @png, "image/png"},
               {"a.png", "alpha", @png, "image/png"}
             ]

    assert result.metadata == %{
             prompt_id: "ordered",
             output_node_ids: ["2", "10", "zeta", "alpha"]
           }

    for filename <- ["two.png", "ten.png", "z1.png", "z2.png", "a.png"],
        do: assert_receive({:view, ^filename})
  end

  test "seed binding generates an ordinary integer without changing the caller graph", ctx do
    graph = Map.put(workflow(), "3", %{"inputs" => %{"seed" => 123, "steps" => 4}})
    cfg = config(ctx.fixture, graph) |> Map.merge(%{seed_node_id: "3", output_node_id: "9"})
    req = %{prompt: " seed 雪\n", model: " workflow ", timeout_ms: 5_000}

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(raw)
      seed = payload["prompt"]["3"]["inputs"]["seed"]
      assert is_integer(seed) and seed >= 0 and seed <= 281_474_976_710_654

      assert put_in(payload, ["prompt", "3", "inputs", "seed"], 123) == %{
               "prompt" => %{
                 "3" => %{"inputs" => %{"seed" => 123, "steps" => 4}},
                 "6" => %{"inputs" => %{"text" => " seed 雪\n"}},
                 "9" => %{"inputs" => %{}}
               }
             }

      json(conn, ~s({"prompt_id":"seeded"}))
    end)

    successful_history(ctx.fixture, "seeded", "seed.png")
    assert {:ok, %{model: "workflow", images: [%{data: @png}]}} = generate(ctx, req, cfg)

    assert graph == %{
             "3" => %{"inputs" => %{"seed" => 123, "steps" => 4}},
             "6" => %{"inputs" => %{"text" => "baked"}},
             "9" => %{"inputs" => %{}}
           }
  end

  test "one linked HTTP owner exits normally after sequential successful work", ctx do
    owner = self()

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      send(owner, {:http_waiting, self()})

      receive do
        :respond -> :ok
      after
        2_000 -> flunk("ordinary response was not released")
      end

      json(conn, ~s({"prompt_id":"owned"}))
    end)

    successful_history(ctx.fixture, "owned", "owned.png")

    caller =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        Comfy.generate(
          %{prompt: "owned", model: "workflow", timeout_ms: 5_000},
          config(ctx.fixture, workflow())
        )
      end)

    assert_receive {:http_waiting, handler}, 2_000
    {:links, links} = Process.info(caller.pid, :links)
    assert [http_owner] = Enum.filter(links, &(is_pid(&1) and &1 != ctx.tasks))
    ref = Process.monitor(http_owner)
    send(handler, :respond)
    assert {:ok, %{images: [%{data: @png}]}} = Task.await(caller, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^http_owner, :normal}, 2_000
  end

  test "all 32 explicit source cases match complete plans and actual sequential HTTP results",
       ctx do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert length(rows) == 39
    assert length(Enum.uniq_by(rows, & &1["id"])) == 39

    assert Enum.map(Enum.reject(rows, & &1["hostComparable"]), & &1["id"]) == [
             "source-only-seed-binding",
             "source-only-alternate-seed-binding",
             "source-only-default-model",
             "source-only-default-timeout",
             "source-only-configured-timeout",
             "source-only-configured-header",
             "source-only-image-overlay"
           ]

    assert capture["providerDescriptor"]["models"] == ["workflow"]
    assert capture["providerDescriptor"]["capabilities"]["generate"]["maxCount"] == 1
    comparable = Enum.filter(rows, & &1["hostComparable"])
    assert length(comparable) == 32

    # Source plans use the production URL and the observed graph before upload.
    # Every plan is compared before transport is substituted for any case.
    for row <- comparable do
      id = row["id"]
      req = source_request(row["input"])
      cfg = source_config(row)
      assert {:ok, built} = Comfy.build_request(req, cfg)
      assert built == source_plan(row), id
      assert row["inputAfter"] == row["input"], id
      assert row["configAfter"] == row["projectedConfig"], id
      assert row["randomCalls"] == [], id
      assert_source_budget(row, built)
    end

    # These are ordinary workflow outputs; count is absent from all three rows.
    for id <- [
          "output-order-integer-keys",
          "output-order-string-keys",
          "output-order-within-node"
        ] do
      row = Enum.find(comparable, &(&1["id"] == id))
      refute Map.has_key?(row["input"], "count")
      assert length(row["result"]["images"]) == 2
    end

    for row <- comparable do
      prefix = "/source/" <> row["id"]
      source_routes(ctx.fixture, prefix, row)
      source_base = row["configCalls"] |> hd() |> get_in(["output", "baseUrl"]) |> URI.parse()

      cfg =
        source_config(row)
        |> Map.put(:base_url, Gaoxy.Test.url(ctx.fixture, prefix <> (source_base.path || "")))

      req = source_request(row["input"])
      assert {:ok, result} = generate(ctx, req, cfg)
      assert result == source_result(row["result"]), row["id"]

      observed =
        for _call <- row["requests"] do
          assert_receive {:source_request, id, index, kind, url}, 2_000
          {id, index, kind, url}
        end

      expected =
        row["requests"]
        |> Enum.with_index()
        |> Enum.map(fn {call, index} -> {row["id"], index, call["kind"], call["url"]} end)

      assert observed == expected, row["id"]
    end
  end

  defp source_request(input) do
    req = %{prompt: input["prompt"], model: input["model"], timeout_ms: input["timeoutMs"]}

    req =
      Enum.reduce(
        [
          {"count", :count},
          {"size", :size},
          {"aspectRatio", :aspect_ratio},
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

  defp source_config(row) do
    config = row["config"]

    cfg = %{
      mode:
        case config["mode"] do
          "local" -> :local
          "cloud" -> :cloud
        end,
      base_url: config["baseUrl"],
      workflow: config["workflow"],
      prompt_node_id: config["promptNodeId"]
    }

    cfg =
      Enum.reduce(
        [
          {"apiKey", :api_key},
          {"headers", :headers},
          {"pollIntervalMs", :poll_interval_ms},
          {"promptInputName", :prompt_input_name},
          {"inputImageNodeId", :input_image_node_id},
          {"inputImageInputName", :input_image_input_name},
          {"outputNodeId", :output_node_id}
        ],
        cfg,
        fn {key, atom}, acc ->
          if Map.has_key?(config, key), do: Map.put(acc, atom, config[key]), else: acc
        end
      )

    if Map.has_key?(row, "mediaMaxMb"),
      do: Map.put(cfg, :max_image_bytes, floor(row["mediaMaxMb"] * 1024 * 1024)),
      else: cfg
  end

  defp source_plan(row) do
    cfg = row["config"]
    prompt = Enum.find(row["requests"], &(&1["kind"] == "prompt"))
    binary_reader = Enum.find(row["readerCalls"], &(&1["kind"] == "binary"))
    request = source_request(row["input"])

    %{
      url: prompt["url"],
      base_url: row["configCalls"] |> hd() |> get_in(["output", "baseUrl"]),
      mode: if(cfg["mode"] == "cloud", do: :cloud, else: :local),
      body: Map.put(prompt["jsonBody"], "prompt", row["preparedBeforeNetwork"]),
      headers: row["configCalls"] |> hd() |> get_in(["output", "headers"]),
      model: row["result"]["model"],
      timeout_ms: min(2_147_000_000, max(1, floor(row["input"]["timeoutMs"]))),
      poll_interval_ms: cfg["pollIntervalMs"],
      max_response_bytes: row["readerCalls"] |> hd() |> Map.fetch!("maxBytes"),
      max_image_bytes: binary_reader["maxBytes"],
      input_image: List.first(request[:input_images] || []),
      input_image_node_id: source_binding(cfg["inputImageNodeId"]),
      input_image_input_name: source_binding(cfg["inputImageInputName"]) || "image",
      output_node_id: source_binding(cfg["outputNodeId"])
    }
  end

  defp source_binding(nil), do: nil
  defp source_binding(value), do: String.trim(value)

  defp source_result(result) do
    %{
      model: result["model"],
      metadata: %{
        prompt_id: result["metadata"]["promptId"],
        output_node_ids: result["metadata"]["outputNodeIds"]
      },
      images:
        Enum.map(result["images"], fn image ->
          %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"],
            metadata: %{
              node_id: image["metadata"]["nodeId"],
              prompt_id: image["metadata"]["promptId"]
            }
          }
        end)
    }
  end

  defp assert_source_budget(row, built) do
    id = row["id"]
    deadline = row["clock"]["deadlineStartMs"] + built.timeout_ms
    assert row["clock"]["deadlineStartMs"] > row["clock"]["startMs"], id
    assert length(row["readerCalls"]) == length(row["requests"]), id
    assert length(row["releaseCalls"]) == length(row["requests"]), id

    for {call, release} <- Enum.zip(row["requests"], row["releaseCalls"]) do
      assert call["timeoutMs"] == deadline - call["atMs"], id
      assert call["timeoutMs"] > 0 and call["timeoutMs"] <= built.timeout_ms, id
      assert call["releaseCount"] == 1, id

      assert release == %{
               "kind" => call["kind"],
               "url" => call["url"],
               "atMs" => call["releasedAtMs"],
               "releaseCount" => 1
             },
             id
    end

    for [earlier, later] <- Enum.chunk_every(row["requests"], 2, 1, :discard) do
      assert earlier["releasedAtMs"] <= later["atMs"], id
      assert earlier["timeoutMs"] > later["timeoutMs"], id
    end

    for reader <- row["readerCalls"] do
      assert reader["remainingBeforeMs"] == deadline - reader["atMs"], id

      assert reader["remainingAfterMs"] > 0 and
               reader["remainingAfterMs"] < reader["remainingBeforeMs"],
             id

      assert reader["hasOnOverflow"] and reader["hasOnIdleTimeout"], id

      case reader["kind"] do
        "json" ->
          assert reader["maxBytes"] == 16_777_216, id
          assert reader["chunkTimeoutMs"] == 30_000, id

        "binary" ->
          assert reader["maxBytes"] == built.max_image_bytes, id
          assert reader["chunkTimeoutMs"] == reader["remainingBeforeMs"], id
      end
    end

    for sleep <- row["sleepCalls"] do
      assert sleep["ms"] == min(built.poll_interval_ms, deadline - sleep["atMs"]), id
    end
  end

  defp source_routes(fixture, prefix, row) do
    owner = self()

    {calls, _counts} =
      row["requests"]
      |> Enum.with_index()
      |> Enum.map_reduce(%{"history" => 0, "download" => 0}, fn {call, index}, counts ->
        kind = call["kind"]
        ordinal = counts[kind]

        counts =
          if kind in ["history", "download"],
            do: Map.update!(counts, kind, &(&1 + 1)),
            else: counts

        {%{call: call, index: index, ordinal: ordinal}, counts}
      end)

    calls
    |> Enum.group_by(fn %{call: call} -> {call["method"], URI.parse(call["url"]).path} end)
    |> Enum.each(fn {{method, path}, route_calls} ->
      sequence = :atomics.new(1, [])

      Gaoxy.Test.expect(
        fixture,
        method,
        prefix <> path,
        fn conn ->
          %{call: call, index: index, ordinal: ordinal} =
            Enum.at(route_calls, :atomics.add_get(sequence, 1, 1) - 1)

          assert conn.query_string == (URI.parse(call["url"]).query || ""), row["id"]

          for {name, value} <- call["headers"],
              do: assert(Plug.Conn.get_req_header(conn, name) == [value], row["id"])

          send(owner, {:source_request, row["id"], index, call["kind"], call["url"]})

          case call["kind"] do
            "upload" ->
              conn = assert_source_multipart(conn, call["fields"], row["id"])
              json(conn, call["responseJson"])

            "prompt" ->
              {:ok, raw, conn} = Plug.Conn.read_body(conn)
              assert Jason.decode!(raw) == call["jsonBody"], row["id"]
              assert call["jsonBody"]["prompt"] == row["preparedWorkflow"], row["id"]
              json(conn, call["responseJson"])

            "history" ->
              raw_history = Enum.at(row["historyJson"], ordinal)
              assert raw_history == call["responseJson"], row["id"]
              json(conn, raw_history)

            "status" ->
              json(conn, call["responseJson"])

            "download" ->
              response = Enum.at(row["responsePlan"]["downloads"], ordinal)

              conn =
                if Map.has_key?(response, "mimeType"),
                  do: Plug.Conn.put_resp_header(conn, "content-type", response["mimeType"]),
                  else: conn

              Plug.Conn.resp(conn, 200, Base.decode64!(response["bytesBase64"]))
          end
        end,
        times: length(route_calls)
      )
    end)
  end

  defp assert_source_multipart(conn, fields, id) do
    assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    assert String.starts_with?(content_type, "multipart/form-data; boundary="), id

    conn =
      Enum.reduce(fields, conn, fn field, conn ->
        {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
        {:ok, bytes, conn} = Plug.Conn.read_part_body(conn, [])

        if Map.has_key?(field, "bytesBase64") do
          assert {"content-disposition",
                  ~s(form-data; name="#{field["name"]}"; filename="#{field["fileName"]}")} in headers,
                 id

          assert {"content-type", field["mimeType"]} in headers, id
          assert bytes == Base.decode64!(field["bytesBase64"]), id
        else
          assert {"content-disposition", ~s(form-data; name="#{field["name"]}")} in headers, id
          assert bytes == field["value"], id
        end

        conn
      end)

    {:done, conn} = Plug.Conn.read_part_headers(conn)
    conn
  end

  defp config(fixture, workflow),
    do: %{
      mode: :local,
      base_url: Gaoxy.Test.url(fixture),
      workflow: workflow,
      prompt_node_id: "6",
      poll_interval_ms: 100
    }

  defp workflow, do: %{"6" => %{"inputs" => %{"text" => "baked"}}, "9" => %{"inputs" => %{}}}

  defp json(conn, body),
    do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)

  defp image(conn, mime \\ "image/png"),
    do: conn |> Plug.Conn.put_resp_header("content-type", mime) |> Plug.Conn.resp(200, @png)

  defp generate(ctx, req, cfg),
    do:
      ctx.tasks
      |> Task.Supervisor.async_nolink(fn -> Comfy.generate(req, cfg) end)
      |> Task.await(5_000)

  defp expect_submit(fixture, prompt, id) do
    Gaoxy.Test.expect_once(fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "prompt" => %{"6" => %{"inputs" => %{"text" => prompt}}, "9" => %{"inputs" => %{}}}
             }

      json(conn, Jason.encode!(%{"prompt_id" => id}))
    end)
  end

  defp successful_history(fixture, id, filename) do
    Gaoxy.Test.expect_once(fixture, "GET", "/history/" <> id, fn conn ->
      json(
        conn,
        Jason.encode!(%{
          "outputs" => %{"9" => %{"images" => [%{"filename" => filename}]}},
          "status" => %{"completed" => true}
        })
      )
    end)

    Gaoxy.Test.expect_once(fixture, "GET", "/view", fn conn ->
      assert conn.query_string == "filename=#{filename}&subfolder=&type=output"
      image(conn)
    end)
  end
end
