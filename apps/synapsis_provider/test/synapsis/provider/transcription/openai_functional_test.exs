defmodule Synapsis.Provider.Transcription.OpenAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Transcription.OpenAI

  @reference Path.expand(
               "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/openai-transcription.json",
               __DIR__
             )
  @ids ~w(default-wav explicit-model language-prompt-unicode blank-optional-fields filename-basename aac-extension aac-extensionless mime-default custom-base response-unicode silence ignored-query buffer-subrange native-mime-case raw-json-bom)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "builds the explicit versioned multipart request with JavaScript whitespace trimming" do
    audio = tiny_wav()

    request = %{
      audio: audio,
      filename: "\uFEFF /recordings/Voice.AAC \uFEFF",
      mime_type: "Audio/AAC",
      model: "\uFEFF custom-transcribe \uFEFF",
      language: "\uFEFF zh \uFEFF",
      prompt: "\uFEFF Names: Ada 雪 \uFEFF",
      timeout_ms: 4_321
    }

    assert {:ok, built} =
             OpenAI.build_request(request, %{
               api_key: "transcription-fixture",
               base_url: "https://speech.example/custom/v1///"
             })

    assert built.url == "https://speech.example/custom/v1/audio/transcriptions"
    assert built.model == "custom-transcribe"
    assert built.timeout_ms == 4_321
    assert built.max_response_bytes == 16 * 1024 * 1024
    assert built.filename == "Voice.m4a"
    assert built.mime_type == "audio/aac"

    assert built.form == [
             {"model", "custom-transcribe"},
             {"language", "zh"},
             {"prompt", "Names: Ada 雪"},
             {"file", {audio, filename: "Voice.m4a", content_type: "audio/aac"}}
           ]
  end

  test "uses the pinned wrapper model and omits empty optional form fields" do
    audio = tiny_wav()

    assert {:ok, built} =
             OpenAI.build_request(
               %{audio: audio, language: " \uFEFF ", prompt: "\uFEFF", timeout_ms: 5_000},
               %{api_key: "transcription-fixture", base_url: "https://speech.example/v1"}
             )

    assert built.model == "gpt-4o-transcribe"
    assert built.filename == "audio"
    assert built.mime_type == "application/octet-stream"

    assert built.form == [
             {"model", "gpt-4o-transcribe"},
             {"file", {audio, filename: "audio", content_type: "application/octet-stream"}}
           ]
  end

  test "ordinary upload names retain the pinned AAC and extension rules" do
    for {filename, mime, expected} <- [
          {"/recordings/clip.AAC", "audio/aac", "clip.m4a"},
          {"clip", " AUDIO/AAC ", "clip.m4a"},
          {".voice", "audio/aac", ".voice.m4a"},
          {".aac", "audio/aac", "audio.m4a"},
          {"clip.", "audio/aac", "clip."},
          {"clip.mp3", "audio/mpeg", "clip.mp3"}
        ] do
      assert {:ok, built} =
               OpenAI.build_request(
                 %{audio: tiny_wav(), filename: filename, mime_type: mime, timeout_ms: 5_000},
                 %{api_key: "transcription-fixture", base_url: "https://speech.example/v1"}
               )

      assert built.filename == expected
    end
  end

  test "successful Blob type normalization preserves ASCII spacing and empty type fallback" do
    for {mime, blob_type, wire_type} <- [
          {"AuDiO/WaV", "audio/wav", "audio/wav"},
          {" Audio/WAV ", " audio/wav ", " audio/wav "},
          {"", "", "application/octet-stream"}
        ] do
      audio = tiny_wav()

      assert {:ok, built} =
               OpenAI.build_request(
                 %{audio: audio, filename: "clip.wav", mime_type: mime, timeout_ms: 5_000},
                 %{api_key: "transcription-fixture", base_url: "https://speech.example/v1"}
               )

      assert built.mime_type == blob_type

      assert List.last(built.form) ==
               {"file", {audio, filename: "clip.wav", content_type: wire_type}}
    end
  end

  test "uploads ordered multipart bytes and returns the selected model with trimmed Unicode text",
       %{fixture: fixture, tasks: tasks} do
    audio = tiny_wav()

    expect_transcription(
      fixture,
      "/custom/api/v1/audio/transcriptions",
      [
        %{name: "model", value: "custom-transcribe"},
        %{name: "language", value: "zh"},
        %{name: "prompt", value: "Names: Ada 雪"},
        %{name: "file", value: audio, filename: "note.m4a", mime_type: "audio/aac"}
      ],
      Jason.encode!(%{text: "\uFEFF  Ada 雪。\n \uFEFF", model: "response-side-model"})
    )

    assert {:ok, %{text: "Ada 雪。", model: "custom-transcribe"}} =
             transcribe(
               tasks,
               %{
                 audio: audio,
                 filename: "/recordings/note.aac",
                 mime_type: "Audio/AAC",
                 model: " custom-transcribe ",
                 language: " zh ",
                 prompt: " Names: Ada 雪 ",
                 timeout_ms: 5_000
               },
               local_config(fixture, "/custom/api/v1///")
             )

    assert_receive {:transcription_upload, _parts}, 1_000
  end

  test "a chunked ordinary JSON transcript succeeds at its raw response byte bound",
       %{fixture: fixture, tasks: tasks} do
    audio = tiny_wav()
    response = Jason.encode!(%{text: "Chunked 雪 transcript."})

    expect_transcription(
      fixture,
      "/v1/audio/transcriptions",
      [
        %{name: "model", value: "gpt-4o-transcribe"},
        %{name: "file", value: audio, filename: "audio", mime_type: "application/octet-stream"}
      ],
      response,
      chunked: true
    )

    config = Map.put(local_config(fixture, "/v1"), :max_response_bytes, byte_size(response))

    assert {:ok, %{text: "Chunked 雪 transcript.", model: "gpt-4o-transcribe"}} =
             transcribe(tasks, %{audio: audio, timeout_ms: 5_000}, config)

    assert_receive {:transcription_upload, _parts}, 1_000
  end

  test "a successful silent transcription retains empty text",
       %{fixture: fixture, tasks: tasks} do
    audio = tiny_wav()

    expect_transcription(
      fixture,
      "/v1/audio/transcriptions",
      [
        %{name: "model", value: "gpt-4o-transcribe"},
        %{name: "file", value: audio, filename: "audio", mime_type: "application/octet-stream"}
      ],
      Jason.encode!(%{text: "\uFEFF \t\n\uFEFF"})
    )

    assert {:ok, %{text: "", model: "gpt-4o-transcribe"}} =
             transcribe(tasks, %{audio: audio, timeout_ms: 5_000}, local_config(fixture, "/v1"))

    assert_receive {:transcription_upload, _parts}, 1_000
  end

  test "a successful JSON response consumes its initial UTF-8 BOM before parsing",
       %{fixture: fixture, tasks: tasks} do
    audio = tiny_wav()
    response = <<0xEF, 0xBB, 0xBF>> <> Jason.encode!(%{text: "\uFEFF  BOM 雪  \uFEFF"})

    expect_transcription(
      fixture,
      "/v1/audio/transcriptions",
      [
        %{name: "model", value: "gpt-4o-transcribe"},
        %{name: "file", value: audio, filename: "audio", mime_type: "application/octet-stream"}
      ],
      response
    )

    assert {:ok, %{text: "BOM 雪", model: "gpt-4o-transcribe"}} =
             transcribe(tasks, %{audio: audio, timeout_ms: 5_000}, local_config(fixture, "/v1"))

    assert_receive {:transcription_upload, _parts}, 1_000
  end

  test "all captured wrapper requests retain their exact fields, native file values and bytes" do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    rows = capture["observations"]
    assert Enum.sort(Enum.map(rows, & &1["id"])) == Enum.sort(@ids)

    for row <- rows do
      request = reference_request(row["input"])
      config = %{api_key: "transcription-fixture", base_url: row["input"]["baseUrl"]}
      assert {:ok, built} = OpenAI.build_request(request, config)
      expected = row["request"]
      file = expected["file"]

      assert built.url == expected["url"], row["id"]
      assert built.model == row["result"]["model"], row["id"]
      assert built.timeout_ms == expected["timeoutMs"], row["id"]
      assert built.max_response_bytes == hd(row["readerCalls"])["maxBytes"], row["id"]
      assert Enum.map(built.form, &elem(&1, 0)) == expected["fieldOrder"], row["id"]
      assert Map.new(Enum.drop(built.form, -1)) == expected["fields"], row["id"]
      assert built.filename == file["name"], row["id"]
      assert built.mime_type == file["blobType"], row["id"]
      assert byte_size(request.audio) == file["size"], row["id"]
      assert request.audio == Base.decode64!(file["bytesBase64"]), row["id"]

      assert List.last(built.form) ==
               {"file",
                {request.audio, filename: file["name"], content_type: file["effectivePartMime"]}},
             row["id"]
    end
  end

  test "all captured successful JSON responses follow actual multipart uploads",
       %{fixture: fixture, tasks: tasks} do
    rows = @reference |> File.read!() |> Jason.decode!() |> Map.fetch!("observations")

    for row <- rows do
      path = "/reference/" <> row["id"] <> "/v1"
      request = reference_request(row["input"])

      expect_transcription(
        fixture,
        path <> "/audio/transcriptions",
        reference_parts(row),
        Base.decode64!(row["response"]["bodyBytesBase64"])
      )

      assert {:ok, result} = transcribe(tasks, request, local_config(fixture, path))
      assert result == %{text: row["result"]["text"], model: row["result"]["model"]}, row["id"]
      assert_receive {:transcription_upload, parts}, 1_000
      assert parts == reference_parts(row), row["id"]
    end
  end

  defp reference_request(input) do
    audio =
      case input["bufferView"] do
        nil ->
          Base.decode64!(input["audioBase64"])

        view ->
          view["backingBytesBase64"]
          |> Base.decode64!()
          |> binary_part(view["byteOffset"], view["byteLength"])
      end

    Enum.reduce(
      [
        {"fileName", :filename},
        {"mime", :mime_type},
        {"model", :model},
        {"language", :language},
        {"prompt", :prompt},
        {"query", :query}
      ],
      %{audio: audio, timeout_ms: input["timeoutMs"]},
      fn {key, atom}, request ->
        case Map.fetch(input, key) do
          {:ok, value} -> Map.put(request, atom, value)
          :error -> request
        end
      end
    )
  end

  defp reference_parts(row) do
    expected = row["request"]

    Enum.map(expected["fieldOrder"], fn
      "file" ->
        file = expected["file"]

        %{
          name: "file",
          value: Base.decode64!(file["bytesBase64"]),
          filename: file["name"],
          mime_type: file["effectivePartMime"]
        }

      name ->
        %{name: name, value: expected["fields"][name]}
    end)
  end

  defp transcribe(tasks, request, config) do
    tasks
    |> Task.Supervisor.async_nolink(fn -> OpenAI.transcribe(request, config) end)
    |> Task.await(10_000)
  end

  defp local_config(fixture, prefix) do
    %{api_key: "transcription-fixture", base_url: Gaoxy.Test.url(fixture, prefix)}
  end

  defp expect_transcription(fixture, path, expected, response, options \\ []) do
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)
      parts = multipart_parts(body, boundary)
      assert parts == expected
      send(owner, {:transcription_upload, parts})
      conn = Plug.Conn.put_resp_content_type(conn, "application/json")

      if Keyword.get(options, :chunked, false) do
        conn = Plug.Conn.send_chunked(conn, 200)
        <<first::binary-size(7), rest::binary>> = response
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
      else
        Plug.Conn.resp(conn, 200, response)
      end
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

  defp tiny_wav do
    <<"RIFF", 38::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data", 2::little-32,
      0::little-signed-16>>
  end
end
