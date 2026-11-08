defmodule Synapsis.Provider.MusicGeneration.ComfyFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MusicGeneration.Comfy

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "default and JS-blank model labels keep exact prompt bytes while raw music controls are ignored" do
    for extra <- [%{}, %{model: nil}, %{model: "\uFEFF \u00A0\n"}] do
      request =
        Map.merge(
          %{
            prompt: "  夜の café 😀\n雪  ",
            timeout_ms: 5_000,
            lyrics: "lyrics do not enter the workflow",
            instrumental: true,
            format: "wav",
            duration_seconds: 37.5
          },
          extra
        )

      cfg = %{
        mode: :local,
        base_url: "\uFEFF http://music.example:8188/root/// \u00A0",
        workflow: workflow(),
        prompt_node_id: "6",
        headers: %{"X-Context" => " ordinary "}
      }

      assert Comfy.build_request(request, cfg) ===
               {:ok,
                %{
                  url: "http://music.example:8188/root/prompt",
                  base_url: "http://music.example:8188/root",
                  mode: :local,
                  body: %{
                    "prompt" => %{
                      "6" => %{"inputs" => %{"text" => "  夜の café 😀\n雪  "}},
                      "9" => %{"inputs" => %{}}
                    }
                  },
                  headers: %{"content-type" => "application/json", "x-context" => "ordinary"},
                  model: "workflow",
                  timeout_ms: 5_000,
                  poll_interval_ms: 1_500,
                  max_response_bytes: 16_777_216,
                  max_audio_bytes: 16_777_216,
                  input_image: nil,
                  input_image_node_id: nil,
                  input_image_input_name: "image",
                  output_node_id: nil
                }}
    end
  end

  test "explicit ordinary audio capacity and fractional timeout use the music plan without an image floor" do
    graph = %{
      "6" => %{"inputs" => %{"positive" => "baked", "negative" => "keep"}},
      "7" => %{"inputs" => %{"pixels" => "original.png"}},
      "9" => %{"inputs" => %{}}
    }

    cfg = %{
      mode: :local,
      base_url: "http://music.example:8188/custom/",
      workflow: graph,
      prompt_node_id: " 6 ",
      prompt_input_name: " positive ",
      input_image_node_id: " 7 ",
      input_image_input_name: " pixels ",
      output_node_id: " 9 ",
      poll_interval_ms: 7,
      max_audio_bytes: 4_096.75
    }

    request = %{prompt: " exact 雪\n", model: "\uFEFF custom label \u00A0", timeout_ms: 5_678.9}

    assert Comfy.build_request(request, cfg) ===
             {:ok,
              %{
                url: "http://music.example:8188/custom/prompt",
                base_url: "http://music.example:8188/custom",
                mode: :local,
                body: %{
                  "prompt" => %{
                    "6" => %{"inputs" => %{"positive" => " exact 雪\n", "negative" => "keep"}},
                    "7" => %{"inputs" => %{"pixels" => "original.png"}},
                    "9" => %{"inputs" => %{}}
                  }
                },
                headers: %{"content-type" => "application/json"},
                model: "custom label",
                timeout_ms: 5_678,
                poll_interval_ms: 7,
                max_response_bytes: 16_777_216,
                max_audio_bytes: 4_096,
                input_image: nil,
                input_image_node_id: "7",
                input_image_input_name: "pixels",
                output_node_id: "9"
              }}

    assert graph === %{
             "6" => %{"inputs" => %{"positive" => "baked", "negative" => "keep"}},
             "7" => %{"inputs" => %{"pixels" => "original.png"}},
             "9" => %{"inputs" => %{}}
           }
  end

  test "local pending history completes with the default model and an unchanged raw prompt",
       ctx do
    owner = self()
    graph = workflow()
    cfg = config(ctx.fixture, graph) |> Map.put(:headers, %{"X-Context" => " ordinary "})

    request = %{
      prompt: "  local 夜 café 😀\n",
      timeout_ms: 5_000,
      lyrics: "ignored lyrics",
      instrumental: true,
      format: "wav",
      duration_seconds: 44.25
    }

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) === %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "  local 夜 café 😀\n"}},
                 "9" => %{"inputs" => %{}}
               }
             }

      assert Plug.Conn.get_req_header(conn, "x-context") === ["ordinary"]
      send(owner, :local_prompt)
      json(conn, ~s({"prompt_id":" p-local "}))
    end)

    polls = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/history/p-local",
      fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-context") === ["ordinary"]

        case :atomics.add_get(polls, 1, 1) do
          1 ->
            send(owner, :pending_history)
            json(conn, "{}")

          2 ->
            send(owner, :completed_history)

            json(
              conn,
              ~s({"outputs":{"9":{"audio":[{"name":" song one.raw ","subfolder":" small set "}]}},"status":{"completed":true},"p-local":{"outputs":{"other":{"audio":[{"filename":"unused.mp3"}]}}}})
            )
        end
      end,
      times: 2
    )

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/view", fn conn ->
      assert conn.query_string === "filename=song+one.raw&subfolder=small+set&type=output"
      assert Plug.Conn.get_req_header(conn, "x-context") === ["ordinary"]
      send(owner, :local_view)
      audio(conn, " Audio/FLAC; source=fixture ", [<<0, 255>>, <<128, 17, 34>>])
    end)

    assert generate(ctx, request, cfg) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128, 17, 34>>,
                    mime_type: "Audio/FLAC; source=fixture",
                    filename: "song one.raw"
                  }
                ],
                model: "workflow",
                metadata: %{prompt_id: "p-local", output_node_ids: ["9"], input_image_count: 0}
              }}

    assert_receive :local_prompt
    assert_receive :pending_history
    assert_receive :completed_history
    assert_receive :local_view
    assert graph === %{"6" => %{"inputs" => %{"text" => "baked"}}, "9" => %{"inputs" => %{}}}
    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "cloud pending and running status reach history_v2 before sequential audio downloads",
       ctx do
    owner = self()

    cfg =
      config(ctx.fixture, workflow())
      |> Map.merge(%{
        mode: :cloud,
        base_url: Gaoxy.Test.url(ctx.fixture, "/cloud"),
        api_key: "explicit-fixture-key"
      })

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/cloud/api/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) === %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "cloud 歌 😀"}},
                 "9" => %{"inputs" => %{}}
               },
               "extra_data" => %{"api_key_comfy_org" => "explicit-fixture-key"}
             }

      send(owner, {:comfy_cloud_step, :prompt})
      json(conn, ~s({"prompt_id":" cloud-one "}))
    end)

    polls = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/cloud/api/job/cloud-one/status",
      fn conn ->
        status = Enum.at(["pending", "running", "completed"], :atomics.add_get(polls, 1, 1) - 1)
        send(owner, {:comfy_cloud_step, {:status, status}})
        json(conn, %{"status" => status})
      end,
      times: 3
    )

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/cloud/api/history_v2/cloud-one", fn conn ->
      send(owner, {:comfy_cloud_step, :history_v2})

      json(
        conn,
        ~s({"cloud-one":{"outputs":{"9":{"audio":[{"filename":"first.ogg"},{"filename":"second.ogg"}]}}}})
      )
    end)

    downloads = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/cloud/api/view",
      fn conn ->
        case :atomics.add_get(downloads, 1, 1) do
          1 ->
            assert conn.query_string === "filename=first.ogg&subfolder=&type=output"
            send(owner, {:comfy_cloud_step, {:view, "first.ogg"}})
            audio(conn, "audio/ogg", [<<0, 255>>])

          2 ->
            assert conn.query_string === "filename=second.ogg&subfolder=&type=output"
            send(owner, {:comfy_cloud_step, {:view, "second.ogg"}})
            audio(conn, "audio/ogg", [<<128, 0>>])
        end
      end,
      times: 2
    )

    assert generate(ctx, %{prompt: "cloud 歌 😀", timeout_ms: 5_000}, cfg) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<0, 255>>, mime_type: "audio/ogg", filename: "first.ogg"},
                  %{data: <<128, 0>>, mime_type: "audio/ogg", filename: "second.ogg"}
                ],
                model: "workflow",
                metadata: %{prompt_id: "cloud-one", output_node_ids: ["9"], input_image_count: 0}
              }}

    steps =
      for _ <- 1..7 do
        assert_receive {:comfy_cloud_step, step}
        step
      end

    assert steps === [
             :prompt,
             {:status, "pending"},
             {:status, "running"},
             {:status, "completed"},
             :history_v2,
             {:view, "first.ogg"},
             {:view, "second.ogg"}
           ]

    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "nil reference MIME uploads exact multipart bytes as PNG and binds the returned name",
       ctx do
    graph = Map.put(workflow(), "7", %{"inputs" => %{"pixels" => "baked.png", "other" => true}})

    cfg =
      config(ctx.fixture, graph)
      |> Map.merge(%{input_image_node_id: "7", input_image_input_name: "pixels"})

    bytes = <<0, 255, 128, 17, 34, 51, 0>>

    request = %{
      prompt: "  remix 雪\n",
      model: " workflow ",
      timeout_ms: 5_000,
      input_images: [%{data: bytes, mime_type: nil}]
    }

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/upload/image", fn conn ->
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "multipart/form-data; boundary=")
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
      assert {"content-disposition", ~s(form-data; name="image"; filename="input.png")} in headers
      assert {"content-type", "image/png"} in headers
      {:ok, actual_bytes, conn} = Plug.Conn.read_part_body(conn, [])
      assert actual_bytes === bytes
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
      assert {"content-disposition", ~s(form-data; name="type")} in headers
      {:ok, "input", conn} = Plug.Conn.read_part_body(conn, [])
      {:ok, headers, conn} = Plug.Conn.read_part_headers(conn)
      assert {"content-disposition", ~s(form-data; name="overwrite")} in headers
      {:ok, "true", conn} = Plug.Conn.read_part_body(conn, [])
      {:done, conn} = Plug.Conn.read_part_headers(conn)

      json(conn, %{
        "filename" => " \uFEFF ",
        "name" => " uploaded music.png ",
        "subfolder" => "ignored"
      })
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) === %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => "  remix 雪\n"}},
                 "7" => %{"inputs" => %{"pixels" => "uploaded music.png", "other" => true}},
                 "9" => %{"inputs" => %{}}
               }
             }

      json(conn, %{"prompt_id" => "edited"})
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/history/edited", fn conn ->
      json(conn, ~s({"outputs":{"9":{"audio":[{"filename":"edited.mp3"}]}}}))
    end)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/view", fn conn ->
      assert conn.query_string === "filename=edited.mp3&subfolder=&type=output"
      audio(conn, "audio/mpeg", [<<255, 128, 0, 42>>])
    end)

    assert generate(ctx, request, cfg) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<255, 128, 0, 42>>, mime_type: "audio/mpeg", filename: "edited.mp3"}
                ],
                model: "workflow",
                metadata: %{prompt_id: "edited", output_node_ids: ["9"], input_image_count: 1}
              }}

    assert graph === %{
             "6" => %{"inputs" => %{"text" => "baked"}},
             "7" => %{"inputs" => %{"pixels" => "baked.png", "other" => true}},
             "9" => %{"inputs" => %{}}
           }

    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "audio buckets keep JavaScript numeric and insertion node order plus array order", ctx do
    owner = self()
    expect_submit(ctx.fixture, "ordered", "ordered")

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/history/ordered", fn conn ->
      json(
        conn,
        ~s({"outputs":{"zeta":{"audio":[{"filename":"z1.mp3"},{"filename":"z2.mp3"}],"images":[{"filename":"ignored-image.png"}]},"10":{"audio":[{"filename":"ten.mp3"}]},"01":{"audio":[{"filename":"zero-one.mp3"}]},"alpha":{"audio":[{"filename":"a.mp3"}]},"8":{"images":[{"filename":"ignored.png"}],"gifs":[{"filename":"ignored.gif"}],"videos":[{"filename":"ignored.mp4"}]},"2":{"audio":[{"filename":"two.mp3"}]}}})
      )
    end)

    downloads = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/view",
      fn conn ->
        index = :atomics.add_get(downloads, 1, 1)

        filename =
          Enum.at(["two.mp3", "ten.mp3", "z1.mp3", "z2.mp3", "zero-one.mp3", "a.mp3"], index - 1)

        assert conn.query_string === "filename=#{filename}&subfolder=&type=output"
        send(owner, {:ordered_view, filename})
        audio(conn, "audio/mpeg", [<<index, 255, 128>>])
      end,
      times: 6
    )

    assert generate(ctx, %{prompt: "ordered", timeout_ms: 5_000}, config(ctx.fixture, workflow())) ===
             {:ok,
              %{
                tracks: [
                  %{data: <<1, 255, 128>>, mime_type: "audio/mpeg", filename: "two.mp3"},
                  %{data: <<2, 255, 128>>, mime_type: "audio/mpeg", filename: "ten.mp3"},
                  %{data: <<3, 255, 128>>, mime_type: "audio/mpeg", filename: "z1.mp3"},
                  %{data: <<4, 255, 128>>, mime_type: "audio/mpeg", filename: "z2.mp3"},
                  %{data: <<5, 255, 128>>, mime_type: "audio/mpeg", filename: "zero-one.mp3"},
                  %{data: <<6, 255, 128>>, mime_type: "audio/mpeg", filename: "a.mp3"}
                ],
                model: "workflow",
                metadata: %{
                  prompt_id: "ordered",
                  output_node_ids: ["2", "10", "zeta", "01", "alpha"],
                  input_image_count: 0
                }
              }}

    for filename <- ["two.mp3", "ten.mp3", "z1.mp3", "z2.mp3", "zero-one.mp3", "a.mp3"],
        do: assert_receive({:ordered_view, ^filename})

    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "selected output node keeps name fallback, full MIME and MIME-independent filenames",
       ctx do
    expect_submit(ctx.fixture, "selected", "selected")
    cfg = config(ctx.fixture, workflow()) |> Map.put(:output_node_id, " chosen ")

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/history/selected", fn conn ->
      json(
        conn,
        ~s({"outputs":{"2":{"audio":[{"filename":"ignored.mp3"}]},"chosen":{"audio":[{"filename":"  ","name":" fallback song.bin ","subfolder":" takes ","type":" temp "},{"filename":" exact.name "}],"images":[{"filename":"ignored-image.png"}]}}})
      )
    end)

    downloads = :atomics.new(1, [])

    Gaoxy.Test.expect(
      ctx.fixture,
      "GET",
      "/view",
      fn conn ->
        case :atomics.add_get(downloads, 1, 1) do
          1 ->
            assert conn.query_string === "filename=fallback+song.bin&subfolder=takes&type=temp"
            audio(conn, nil, [<<0, 255, 128>>])

          2 ->
            assert conn.query_string === "filename=exact.name&subfolder=&type=output"
            audio(conn, " Audio/WAV; codec=fixture ", [<<17>>, <<34, 51>>])
        end
      end,
      times: 2
    )

    request = %{prompt: "selected", model: "\uFEFF music label \u00A0", timeout_ms: 5_000}

    assert generate(ctx, request, cfg) ===
             {:ok,
              %{
                tracks: [
                  %{
                    data: <<0, 255, 128>>,
                    mime_type: "application/octet-stream",
                    filename: "fallback song.bin"
                  },
                  %{
                    data: <<17, 34, 51>>,
                    mime_type: "Audio/WAV; codec=fixture",
                    filename: "exact.name"
                  }
                ],
                model: "music label",
                metadata: %{
                  prompt_id: "selected",
                  output_node_ids: ["chosen"],
                  input_image_count: 0
                }
              }}

    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "builder binds an ordinary random seed while the entire caller graph remains unchanged" do
    graph = %{
      "3" => %{"inputs" => %{"noise" => 111, "steps" => 4}},
      "6" => %{"inputs" => %{"text" => "baked", "other" => [1, 2]}},
      "9" => %{"inputs" => %{}}
    }

    cfg = %{
      mode: :local,
      base_url: "http://music.example:8188",
      workflow: graph,
      prompt_node_id: "6",
      seed_node_id: " 3 ",
      seed_input_name: " noise ",
      output_node_id: "9"
    }

    assert {:ok, built} =
             Comfy.build_request(%{prompt: " seed 雪\n", timeout_ms: 5_000}, cfg)

    seed = built.body["prompt"]["3"]["inputs"]["noise"]
    assert is_integer(seed) and seed >= 0 and seed <= 281_474_976_710_654

    assert put_in(built, [:body, "prompt", "3", "inputs", "noise"], 111) === %{
             url: "http://music.example:8188/prompt",
             base_url: "http://music.example:8188",
             mode: :local,
             body: %{
               "prompt" => %{
                 "3" => %{"inputs" => %{"noise" => 111, "steps" => 4}},
                 "6" => %{"inputs" => %{"text" => " seed 雪\n", "other" => [1, 2]}},
                 "9" => %{"inputs" => %{}}
               }
             },
             headers: %{"content-type" => "application/json"},
             model: "workflow",
             timeout_ms: 5_000,
             poll_interval_ms: 1_500,
             max_response_bytes: 16_777_216,
             max_audio_bytes: 16_777_216,
             input_image: nil,
             input_image_node_id: nil,
             input_image_input_name: "image",
             output_node_id: "9"
           }

    assert graph === %{
             "3" => %{"inputs" => %{"noise" => 111, "steps" => 4}},
             "6" => %{"inputs" => %{"text" => "baked", "other" => [1, 2]}},
             "9" => %{"inputs" => %{}}
           }
  end

  defp expect_submit(fixture, prompt, prompt_id) do
    Gaoxy.Test.expect_once(fixture, "POST", "/prompt", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) === %{
               "prompt" => %{
                 "6" => %{"inputs" => %{"text" => prompt}},
                 "9" => %{"inputs" => %{}}
               }
             }

      json(conn, %{"prompt_id" => prompt_id})
    end)
  end

  defp json(conn, payload) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, body)
  end

  defp audio(conn, mime, chunks) do
    conn = if mime, do: Plug.Conn.put_resp_header(conn, "content-type", mime), else: conn
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn chunk, acc ->
      {:ok, next} = Plug.Conn.chunk(acc, chunk)
      next
    end)
  end

  defp generate(ctx, request, cfg) do
    task = Task.Supervisor.async_nolink(ctx.tasks, fn -> Comfy.generate(request, cfg) end)
    Task.await(task, 10_000)
  end

  defp config(fixture, graph),
    do: %{
      mode: :local,
      base_url: Gaoxy.Test.url(fixture, "/"),
      workflow: graph,
      prompt_node_id: "6",
      poll_interval_ms: 1
    }

  defp workflow,
    do: %{"6" => %{"inputs" => %{"text" => "baked"}}, "9" => %{"inputs" => %{}}}
end
