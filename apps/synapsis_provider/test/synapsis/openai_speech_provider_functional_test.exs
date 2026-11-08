defmodule Synapsis.OpenAISpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Transcription}
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "OpenAI Speech is an explicit editable speech preset outside the seeded defaults" do
    assert "openai_speech" in ProviderConfig.valid_types()

    assert %{
             name: "openai-speech",
             label: "OpenAI Speech",
             type: "openai_speech",
             base_url: "https://api.openai.com",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "openai-speech"))

    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "openai-speech"))

    for record <- original do
      assert {:ok, ^record} = Store.get(:provider, record["id"])
    end

    assert %{type: "openai"} =
             Enum.find(Providers.preset_providers(), &(&1.name == "openai"))

    assert Providers.speech_capabilities(%{type: "openai_speech"}) == [:tts, :stt]
    assert Providers.speech_capabilities(%{type: "elevenlabs"}) == [:tts]
    assert Providers.speech_capabilities(%{type: "openai"}) == []
    assert Providers.speech_only?(%{type: "openai_speech"})
    assert Providers.speech_only?(%{type: "elevenlabs"})
  end

  test "the saved speech identity and current credential survive TOML reload without LLM models" do
    credential = credential!()
    provider = provider!(credential, %{"voice" => "coral"})
    assert {:ok, ^provider} = Providers.get(provider.id)
    assert {:ok, ^provider} = Providers.get_by_name(provider.name)
    provider_id = provider.id
    assert {:ok, ^provider_id} = Ecto.UUID.cast(provider_id)
    assert Providers.speech_capabilities(provider) == [:tts, :stt]
    assert Providers.model_suggestions(provider) == []
    assert {:ok, []} = Models.list(provider_id: provider.id)

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == provider.id))
    assert persisted["type"] == "openai_speech"
    assert persisted["preset"] == "openai-speech"
    assert persisted["credential_id"] == credential.id
    assert persisted["config"]["voice"] == "coral"

    assert {:ok, _} = Credentials.update(credential.id, %{key: "updated-speech-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.name == provider.name
    assert reloaded.type == "openai_speech"
    assert reloaded.credential_id == credential.id
    assert {:ok, runtime} = Providers.runtime_config(provider.name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == provider.name
    assert runtime.type == "openai_speech"
    assert runtime.base_url == "https://api.openai.com"
    assert runtime.api_key == "updated-speech-fixture"
    assert {:ok, ^runtime} = Registry.get(provider.name)
  end

  for {label, base_path, endpoint, overrides, expected_fields} <- [
        {"API root and adapter defaults", "/", "/v1/audio/transcriptions", %{},
         [{"model", "gpt-4o-transcribe"}]},
        {"versioned API prefix", "/v1/", "/v1/audio/transcriptions", %{},
         [{"model", "gpt-4o-transcribe"}]},
        {"custom API prefix and explicit context", "/custom/api/v1///",
         "/custom/api/v1/audio/transcriptions",
         %{model: " custom-transcribe ", language: " zh ", prompt: " Names: Ada 雪 "},
         [{"model", "custom-transcribe"}, {"language", "zh"}, {"prompt", "Names: Ada 雪"}]}
      ] do
    @base_path base_path
    @endpoint endpoint
    @overrides overrides
    @expected_fields expected_fields
    test "saved OpenAI Speech transcribes through #{label}" do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      tasks = start_supervised!({Task.Supervisor, []})
      credential = credential!()
      provider = provider!(credential, %{}, Gaoxy.Test.url(fixture, @base_path))
      assert {:ok, _} = Credentials.update(credential.id, %{key: "current-speech-fixture"})
      assert {:ok, provider} = Providers.get(provider.id)
      assert {:ok, stored_provider} = Store.get(:provider, provider.id)
      audio = tiny_wav()
      owner = self()

      expected =
        Enum.map(@expected_fields, fn {name, value} -> %{name: name, value: value} end) ++
          [%{name: "file", value: audio, filename: "voice.wav", mime_type: "audio/wav"}]

      Gaoxy.Test.expect_once(fixture, "POST", @endpoint, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer current-speech-fixture"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        [_, boundary] = Regex.run(~r/^multipart\/form-data; boundary=(.+)$/, content_type)
        parts = multipart_parts(body, boundary)
        assert parts == expected
        send(owner, {:speech_transcription_upload, parts})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{text: "\uFEFF  Ada 雪。\n \uFEFF"}))
      end)

      request =
        Map.merge(
          %{audio: audio, filename: "voice.wav", mime_type: "audio/wav", timeout_ms: 5_000},
          @overrides
        )

      expected_model = @expected_fields |> List.first() |> elem(1)

      assert {:ok, %{text: "Ada 雪。", model: ^expected_model}} =
               tasks
               |> Task.Supervisor.async_nolink(fn ->
                 Transcription.transcribe(provider.name, request)
               end)
               |> Task.await(10_000)

      assert_receive {:speech_transcription_upload, ^expected}, 1_000
      assert {:ok, current} = Providers.get(provider.id)
      assert current == provider
      assert {:ok, ^stored_provider} = Store.get(:provider, provider.id)
    end
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "openai-speech-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp provider!(credential, config, base_url \\ nil) do
    assert {:ok, provider} =
             Providers.create(%{
               name: "openai-speech-#{Ecto.UUID.generate()}",
               type: "openai_speech",
               preset: "openai-speech",
               base_url: base_url,
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    provider
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
