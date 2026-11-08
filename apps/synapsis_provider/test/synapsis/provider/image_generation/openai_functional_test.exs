defmodule Synapsis.Provider.ImageGeneration.OpenAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ImageGeneration.OpenAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openai-image-generation.json",
               __DIR__
             )
  @ids ~w(default-size explicit-count legacy-closest-size native-closest-size flexible-gpt-image-2 flexible-dated-model flexible-gpt-image-2.5 auto-gpt-image-2.5 jpeg-options webp-options png-options custom-prefix edit-one edit-many-native-mime ordered-inline ordered-urls mixed-inline-url usage-zero-nested usage-absent azure-default-version azure-explicit-version-edit source-only-transparent-reroute)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builds generation options with provider precedence and an explicit model" do
    request = %{
      prompt: "A snowy mountain 雪",
      model: "gpt-image-2.5-flare",
      timeout_ms: 4_321,
      count: 3,
      size: "auto",
      quality: "xhigh",
      output_format: "webp",
      background: "opaque",
      provider_options: %{
        openai: %{
          background: "transparent",
          moderation: "low",
          output_compression: 71,
          user: "artist"
        }
      }
    }

    assert {:ok, built} = OpenAI.build_request(request, config("https://api.openai.com/v1///"))
    assert built.url == "https://api.openai.com/v1/images/generations"
    assert built.model == "gpt-image-2.5-flare"
    assert built.timeout_ms == 4_321
    assert built.max_image_bytes == 64 * 1024 * 1024
    assert built.max_response_bytes == div(64 * 1024 * 1024 * 3 * 4 + 2, 3) + 1024 * 1024

    assert built.body == %{
             "model" => "gpt-image-2.5-flare",
             "prompt" => "A snowy mountain 雪",
             "n" => 3,
             "size" => "auto",
             "quality" => "xhigh",
             "output_format" => "webp",
             "background" => "transparent",
             "moderation" => "low",
             "output_compression" => 71,
             "user" => "artist"
           }
  end

  test "default PNG omits compression while retaining the saved model on a custom endpoint" do
    request =
      Map.merge(request(), %{
        background: "transparent",
        provider_options: %{openai: %{output_compression: 50}}
      })

    assert {:ok, built} =
             OpenAI.build_request(request, config("https://images.example/custom/v1/"))

    assert built.url == "https://images.example/custom/v1/images/generations"

    assert built.body == %{
             "model" => "gpt-image-2",
             "prompt" => "A snowy mountain",
             "n" => 1,
             "size" => "1024x1024",
             "background" => "transparent"
           }
  end

  test "native geometry preserves flexible dimensions and normalizes legacy sizes" do
    for {model, requested, expected, metadata} <- [
          {"gpt-image-2", "1600x1024", "1600x1024", nil},
          {"gpt-image-2-2026-04-21", "1024x1600", "1024x1600", nil},
          {"gpt-image-2.5-sunburst", "auto", "auto", nil},
          {"gpt-image-1", "2048x2048", "1024x1024",
           %{"requestedSize" => "2048x2048", "normalizedSize" => "1024x1024"}},
          {"gpt-image-1.5", "2000x1125", "2048x1152",
           %{"requestedSize" => "2000x1125", "normalizedSize" => "2048x1152"}}
        ] do
      assert {:ok, built} =
               OpenAI.build_request(
                 Map.merge(request(), %{model: model, size: requested}),
                 config("https://api.openai.com/v1")
               )

      assert built.body["size"] == expected
      assert built[:metadata] == metadata
    end

    assert {:ok, built} =
             OpenAI.build_request(
               Map.put(request(), :size, "2000x1125"),
               config("https://images.example/v1")
             )

    assert built.body["size"] == "2000x1125"
    refute Map.has_key?(built, :metadata)
  end

  test "official hostname case retains native geometry and the configured request URL" do
    base_url = "https://API.OPENAI.COM/v1"

    assert {:ok, built} =
             OpenAI.build_request(
               Map.merge(request(), %{model: "gpt-image-1", size: "2048x2048"}),
               config(base_url)
             )

    assert built.url == base_url <> "/images/generations"
    assert built.model == "gpt-image-1"
    assert built.body["size"] == "1024x1024"
    assert built.metadata == %{"requestedSize" => "2048x2048", "normalizedSize" => "1024x1024"}
  end

  test "ordered edit fields precede source images and retain upload bytes and MIME" do
    inputs = [
      %{
        data: <<137, 80, 78, 71>>,
        mime_type: " Image/PNG ",
        filename: " \uFEFF /photos/snow.png \uFEFF"
      },
      %{data: <<255, 216, 255>>, mime_type: "image/jpeg"},
      %{data: "third"}
    ]

    req =
      Map.merge(request(), %{
        input_images: inputs,
        count: 2,
        quality: "high",
        output_format: "jpeg",
        provider_options: %{openai: %{output_compression: 0, user: "artist"}}
      })

    assert {:ok, built} = OpenAI.build_request(req, config("https://images.example/v1"))
    assert built.url == "https://images.example/v1/images/edits"

    assert built.form == [
             {"model", "gpt-image-2"},
             {"prompt", "A snowy mountain"},
             {"n", "2"},
             {"size", "1024x1024"},
             {"quality", "high"},
             {"output_format", "jpeg"},
             {"output_compression", "0"},
             {"user", "artist"},
             {"image[]", {<<137, 80, 78, 71>>, filename: "snow.png", content_type: "image/png"}},
             {"image[]",
              {<<255, 216, 255>>, filename: "image-2.jpg", content_type: "image/jpeg"}},
             {"image[]", {"third", filename: "image-3.png", content_type: "image/png"}}
           ]
  end

  test "Azure deployment URLs use the configured version and omit the body model" do
    assert {:ok, built} =
             OpenAI.build_request(
               Map.put(request(), :model, "studio"),
               Map.merge(config("https://studio.openai.azure.com/openai/v1/"), %{
                 api_version: "2025-04-01-preview"
               })
             )

    assert built.url ==
             "https://studio.openai.azure.com/openai/deployments/studio/images/generations?api-version=2025-04-01-preview"

    assert built.body == %{"prompt" => "A snowy mountain", "n" => 1, "size" => "1024x1024"}

    assert {:ok, built} =
             OpenAI.build_request(
               request(),
               Map.put(config("https://studio.services.ai.azure.com/v1"), :api_style, :azure)
             )

    assert String.ends_with?(built.url, "?api-version=2024-12-01-preview")
  end

  test "generation POST returns ordered inline bytes, explicit MIME and Unicode revised prompts",
       %{fixture: fixture, tasks: tasks} do
    first = <<137, 80, 78, 71, 13, 10, 26, 10>>
    second = <<255, 216, 255, 224>>

    response = %{
      "data" => [
        %{"b64_json" => Base.encode64(first), "revised_prompt" => "\uFEFF Snow 雪 \uFEFF"},
        %{
          "b64_json" => Base.encode64(second),
          "mime_type" => " image/jpeg ",
          "revised_prompt" => " "
        }
      ]
    }

    expect_json(
      fixture,
      "/custom/v1/images/generations",
      %{
        "model" => "gpt-image-2",
        "prompt" => "A snowy mountain",
        "n" => 2,
        "size" => "1024x1024"
      },
      response
    )

    assert {:ok, result} =
             generate(tasks, Map.put(request(), :count, 2), local_config(fixture, "/custom/v1"))

    assert result == %{
             model: "gpt-image-2",
             images: [
               %{
                 data: first,
                 mime_type: "image/png",
                 filename: "image-1.png",
                 revised_prompt: "Snow 雪"
               },
               %{data: second, mime_type: "image/jpeg", filename: "image-2.jpg"}
             ]
           }
  end

  test "ordinary URL downloads interleave with inline assets in response order", %{
    fixture: fixture,
    tasks: tasks
  } do
    owner = self()

    for {path, bytes, mime} <- [
          {"/assets/first", "first", "Image/WebP; charset=binary"},
          {"/assets/last", "last", "image/jpeg"}
        ] do
      Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
        send(owner, {:download, path})
        conn |> Plug.Conn.put_resp_header("content-type", mime) |> Plug.Conn.resp(200, bytes)
      end)
    end

    response = %{
      "data" => [
        %{"url" => Gaoxy.Test.url(fixture, "/assets/first"), "revised_prompt" => " first "},
        %{"b64_json" => Base.encode64("middle"), "mime_type" => "image/png"},
        %{"url" => Gaoxy.Test.url(fixture, "/assets/last")}
      ]
    }

    expect_json(
      fixture,
      "/v1/images/generations",
      %{
        "model" => "gpt-image-2",
        "prompt" => "A snowy mountain",
        "n" => 3,
        "size" => "1024x1024"
      },
      response
    )

    assert {:ok, result} =
             generate(tasks, Map.put(request(), :count, 3), local_config(fixture, "/v1"))

    assert result.images == [
             %{
               data: "first",
               mime_type: "image/webp",
               filename: "image-1.webp",
               revised_prompt: "first"
             },
             %{data: "middle", mime_type: "image/png", filename: "image-2.png"},
             %{data: "last", mime_type: "image/jpeg", filename: "image-3.jpg"}
           ]

    assert_receive {:download, "/assets/first"}
    assert_receive {:download, "/assets/last"}
  end

  test "actual edits upload ordered multipart and consume chunked JSON at its byte bound", %{
    fixture: fixture,
    tasks: tasks
  } do
    response =
      Jason.encode!(%{
        "data" => [%{"b64_json" => Base.encode64("result")}],
        "usage" => %{
          "input_tokens" => 0,
          "output_tokens" => 12,
          "total_tokens" => 12,
          "input_tokens_details" => %{"text_tokens" => 0, "image_tokens" => 0},
          "output_tokens_details" => %{"text_tokens" => 2, "image_tokens" => 10}
        }
      })

    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/images/edits", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)

      assert multipart_parts(body, boundary) == [
               %{name: "model", value: "gpt-image-2"},
               %{name: "prompt", value: "A snowy mountain"},
               %{name: "n", value: "1"},
               %{name: "size", value: "1024x1024"},
               %{name: "output_format", value: "webp"},
               %{
                 name: "image[]",
                 value: "source",
                 filename: "original.png",
                 mime_type: "image/png"
               }
             ]

      send(owner, :edited)

      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      <<first::binary-size(9), rest::binary>> = response
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)

    req =
      Map.merge(request(), %{
        output_format: "webp",
        input_images: [%{data: "source", filename: "/photos/original.png"}]
      })

    cfg =
      Map.merge(local_config(fixture, "/v1"), %{
        max_response_bytes: byte_size(response),
        max_image_bytes: 6
      })

    assert {:ok, result} = generate(tasks, req, cfg)
    assert result.images == [%{data: "result", mime_type: "image/webp", filename: "image-1.webp"}]

    assert result.metadata["usage"] == %{
             "input_tokens" => 0,
             "output_tokens" => 12,
             "total_tokens" => 12,
             "input_tokens_details" => %{"text_tokens" => 0, "image_tokens" => 0},
             "output_tokens_details" => %{"text_tokens" => 2, "image_tokens" => 10}
           }

    assert_receive :edited
  end

  test "local Azure generation executes the deployment endpoint and carries geometry metadata", %{
    fixture: fixture,
    tasks: tasks
  } do
    path = "/openai/deployments/gpt-image-1/images/generations"

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      assert conn.query_string == "api-version=2025-04-01-preview"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "prompt" => "A snowy mountain",
               "n" => 1,
               "size" => "1024x1024"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64("azure")}], "usage" => %{}})
      )
    end)

    cfg =
      Map.merge(local_config(fixture, "/v1"), %{
        api_style: :azure,
        api_version: "2025-04-01-preview"
      })

    assert {:ok, result} =
             generate(
               tasks,
               Map.merge(request(), %{model: "gpt-image-1", size: "2048x2048"}),
               cfg
             )

    assert result.metadata == %{"requestedSize" => "2048x2048", "normalizedSize" => "1024x1024"}
    assert result.images == [%{data: "azure", mime_type: "image/png", filename: "image-1.png"}]
  end

  test "all comparable source requests preserve their exact JSON or native multipart plan" do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert Enum.sort(Enum.map(capture["observations"], & &1["id"])) == Enum.sort(@ids)

    rows = Enum.filter(capture["observations"], & &1["hostComparable"])
    assert length(rows) == 21

    for row <- rows do
      assert {:ok, built} =
               OpenAI.build_request(
                 reference_request(row["input"]),
                 reference_config(row["config"])
               )

      assert built.url == row["request"]["url"], row["id"]
      assert built.timeout_ms == row["request"]["timeoutMs"], row["id"]
      assert built.model == row["result"]["model"], row["id"]
      assert built.max_response_bytes == hd(row["readerCalls"])["maxBytes"], row["id"]
      assert built.max_image_bytes == 64 * 1024 * 1024, row["id"]
      expected_metadata = Map.drop(row["result"]["metadata"] || %{}, ["usage"])
      assert (built[:metadata] || %{}) == expected_metadata, row["id"]

      if row["request"]["jsonBody"] do
        assert built.body == row["request"]["jsonBody"], row["id"]
      else
        assert built.form == reference_form(row), row["id"]
      end
    end
  end

  test "all comparable source rows retain actual HTTP fields, uploads, ordered downloads and result bytes",
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

      assert {:ok, built} =
               OpenAI.build_request(
                 reference_request(row["input"]),
                 reference_config(row["config"])
               )

      prefix = "/reference/" <> id
      azure = built.api_style == :azure
      action = if row["request"]["formEntries"], do: "edits", else: "generations"

      path =
        if azure,
          do: prefix <> "/openai/deployments/" <> built.model <> "/images/" <> action,
          else: prefix <> "/v1/images/" <> action

      expected_query = URI.parse(built.url).query || ""

      downloads = row["response"]["downloads"]

      replacements =
        downloads
        |> Enum.with_index()
        |> Map.new(fn {download, index} ->
          download_path = prefix <> "/assets/" <> Integer.to_string(index)

          Gaoxy.Test.expect_once(fixture, "GET", download_path, fn conn ->
            send(owner, {:reference_download, id, download["url"]})

            conn
            |> Plug.Conn.put_resp_header("content-type", download["contentType"])
            |> Plug.Conn.resp(200, Base.decode64!(download["bytesBase64"]))
          end)

          {download["url"], Gaoxy.Test.url(fixture, download_path)}
        end)

      response =
        Map.update!(row["response"]["json"], "data", fn entries ->
          Enum.map(entries, fn entry ->
            if Map.has_key?(replacements, entry["url"]),
              do: Map.put(entry, "url", replacements[entry["url"]]),
              else: entry
          end)
        end)

      Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
        assert conn.query_string == expected_query, id
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if expected = row["request"]["jsonBody"] do
          assert Jason.decode!(body) == expected, id
        else
          [content_type] = Plug.Conn.get_req_header(conn, "content-type")
          [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)
          assert multipart_parts(body, boundary) == reference_parts(row), id
        end

        send(owner, {:reference_post, id})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      # A local custom base replaces the public transport. Original native geometry
      # was checked above, so replay its resolved wire size; Azure retains its full
      # geometry path through explicit api_style. No public provider is contacted.
      normalized_public = not azure and Map.has_key?(built, :metadata)
      request = reference_request(row["input"])
      size = (built[:body] || Map.new(built.form))["size"]
      request = if normalized_public, do: Map.put(request, :size, size), else: request

      config =
        reference_config(row["config"])
        |> Map.put(:base_url, Gaoxy.Test.url(fixture, prefix <> "/v1"))
        |> Map.put(:api_style, built.api_style)

      assert {:ok, result} = generate(tasks, request, config)
      assert result == reference_result(row, normalized_public), id
      assert_receive {:reference_post, ^id}, 1_000

      received =
        Enum.map(downloads, fn _ ->
          assert_receive {:reference_download, ^id, url}, 1_000
          url
        end)

      assert received == Enum.map(downloads, & &1["url"]), id
    end
  end

  defp reference_request(input) do
    request =
      Enum.reduce(
        [
          {"count", :count},
          {"size", :size},
          {"quality", :quality},
          {"outputFormat", :output_format},
          {"background", :background}
        ],
        %{prompt: input["prompt"], model: input["model"], timeout_ms: input["timeoutMs"]},
        fn {key, atom}, acc ->
          if Map.has_key?(input, key), do: Map.put(acc, atom, input[key]), else: acc
        end
      )

    request =
      if images = input["inputImages"] do
        Map.put(
          request,
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
        request
      end

    if options = get_in(input, ["providerOptions", "openai"]) do
      mapped =
        Enum.reduce(
          [
            {"background", :background},
            {"moderation", :moderation},
            {"outputCompression", :output_compression},
            {"user", :user}
          ],
          %{},
          fn {key, atom}, acc ->
            if Map.has_key?(options, key), do: Map.put(acc, atom, options[key]), else: acc
          end
        )

      Map.put(request, :provider_options, %{openai: mapped})
    else
      request
    end
  end

  defp reference_config(input) do
    config = config(input["baseUrl"])
    if input["apiVersion"], do: Map.put(config, :api_version, input["apiVersion"]), else: config
  end

  defp reference_form(row) do
    Enum.map(row["request"]["formEntries"], fn entry ->
      if Map.has_key?(entry, "value") do
        {entry["name"], entry["value"]}
      else
        {entry["name"],
         {Base.decode64!(entry["bytesBase64"]),
          filename: entry["fileName"], content_type: entry["mimeType"]}}
      end
    end)
  end

  defp reference_parts(row) do
    Enum.map(row["request"]["formEntries"], fn entry ->
      if Map.has_key?(entry, "value") do
        %{name: entry["name"], value: entry["value"]}
      else
        %{
          name: entry["name"],
          value: Base.decode64!(entry["bytesBase64"]),
          filename: entry["fileName"],
          mime_type: entry["mimeType"]
        }
      end
    end)
  end

  defp reference_result(row, normalized_public) do
    result = %{
      model: row["result"]["model"],
      images:
        Enum.map(row["result"]["images"], fn image ->
          asset = %{
            data: Base.decode64!(image["bytesBase64"]),
            mime_type: image["mimeType"],
            filename: image["fileName"]
          }

          if image["revisedPrompt"],
            do: Map.put(asset, :revised_prompt, image["revisedPrompt"]),
            else: asset
        end)
    }

    metadata = row["result"]["metadata"] || %{}

    metadata =
      if normalized_public,
        do: Map.drop(metadata, ["requestedSize", "normalizedSize"]),
        else: metadata

    if metadata == %{}, do: result, else: Map.put(result, :metadata, metadata)
  end

  defp request, do: %{prompt: "A snowy mountain", model: "gpt-image-2", timeout_ms: 5_000}
  defp config(base_url), do: %{api_key: "image-fixture", base_url: base_url}
  defp local_config(fixture, prefix), do: config(Gaoxy.Test.url(fixture, prefix))

  defp generate(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> OpenAI.generate(request, config) end)
    |> Task.await(10_000)
  end

  defp expect_json(fixture, path, expected, response) do
    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == expected

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
