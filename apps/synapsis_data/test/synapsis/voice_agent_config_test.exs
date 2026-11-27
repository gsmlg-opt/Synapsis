defmodule Synapsis.VoiceAgentConfigTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfig, AgentConfigs, Config.Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    File.chmod!(tmp_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", tmp_dir)
    File.write!(Store.file_path(:agent), "")
    :ok = Store.reload(:agent)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      Store.reload(:agent)
    end)

    :ok
  end

  test "legacy TOML keeps the standard runtime default" do
    id = Ecto.UUID.generate()
    assert {:ok, _} = Store.put(:agent, %{"id" => id, "name" => "legacy"})
    assert Map.get(AgentConfigs.get(id), :kind) == :standard
  end

  test "voice configuration survives create, update and TOML reload" do
    attrs = %{
      name: "voice",
      kind: :host_voice,
      provider: "backplane",
      voice_model: "openai/gpt-realtime",
      voice: "marin",
      voice_turn_detection: "semantic_vad",
      audio_mode: "host",
      host_audio_input_device: "input-device",
      host_audio_output_device: "output-device",
      host_audio_input_volume: 0,
      host_audio_output_volume: 65,
      voice_delegate: "builder"
    }

    assert {:ok, agent} = AgentConfigs.create(attrs)
    assert :ok = Store.reload(:agent)
    saved = AgentConfigs.get(agent.id)
    for {field, value} <- attrs, do: assert(Map.get(saved, field) == value)
    assert {:ok, updated} = AgentConfigs.update(saved, %{kind: :voice, voice: "cedar"})
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(agent.id) == updated
    assert {:ok, raw} = Store.get(:agent, agent.id)
    assert raw["kind"] == "voice"
    assert raw["voice_model"] == "openai/gpt-realtime"
    assert raw["host_audio_output_volume"] == 65

    assert {:ok, louder} = AgentConfigs.update(updated, %{browser_audio_output_volume: 180})
    assert {:ok, switched} = AgentConfigs.update(louder, %{kind: :host_voice})
    assert switched.browser_audio_output_volume == 180
    assert switched.host_audio_output_volume == 65
    assert {:error, invalid} = AgentConfigs.update(switched, %{host_audio_output_volume: 180})
    assert Keyword.has_key?(invalid.errors, :host_audio_output_volume)
  end

  test "legacy preferences migrate to their saved endpoint and stay cleared across reload" do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Store.put(:agent, %{
               "id" => id,
               "name" => "legacy-voice",
               "kind" => "voice",
               "provider" => "backplane",
               "voice_model" => "openai/gpt-realtime",
               "audio_mode" => "host",
               "audio_input_device" => "original-host-mic",
               "audio_output_volume" => 90
             })

    saved = AgentConfigs.get(id)
    assert saved.kind == :voice
    assert saved.audio_mode == "browser"
    assert saved.host_audio_input_device == "original-host-mic"
    assert saved.host_audio_output_volume == 90
    assert saved.browser_audio_input_device == nil

    assert {:ok, _} =
             AgentConfigs.update(saved, %{
               audio_mode: "browser",
               host_audio_input_device: nil,
               browser_audio_input_device: "new-browser-mic"
             })

    assert :ok = Store.reload(:agent)
    updated = AgentConfigs.get(id)
    assert updated.host_audio_input_device == nil
    assert updated.host_audio_output_volume == 90
    assert updated.browser_audio_input_device == "new-browser-mic"
  end

  test "the saved browser default speaker resolves to an unset override" do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Store.put(:agent, %{
               "id" => id,
               "name" => "default-speaker",
               "kind" => "voice",
               "provider" => "backplane",
               "voice_model" => "openai/gpt-realtime",
               "audio_mode" => "browser",
               "audio_output_device" => "default",
               "host_audio_output_device" => "default"
             })

    saved = AgentConfigs.get(id)
    assert saved.browser_audio_output_device == nil
    assert saved.host_audio_output_device == "default"

    assert {:ok, selected} =
             AgentConfigs.update(saved, %{browser_audio_output_device: "specific-device"})

    assert selected.browser_audio_output_device == "specific-device"

    assert {:ok, default} =
             AgentConfigs.update(selected, %{browser_audio_output_device: "default"})

    assert default.browser_audio_output_device == nil
  end

  test "voice validation requires explicit routing and rejects arbitrary audio options" do
    changeset = AgentConfig.changeset(%AgentConfig{}, %{name: "voice", kind: "voice"})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :provider)
    assert Keyword.has_key?(changeset.errors, :voice_model)

    changeset =
      AgentConfig.changeset(%AgentConfig{}, %{
        name: "voice",
        kind: "voice",
        provider: "backplane",
        voice_model: "plain-model",
        audio_mode: "remote",
        voice_turn_detection: "automatic",
        voice: "unvalidated"
      })

    for field <- [:voice_model, :audio_mode, :voice_turn_detection, :voice],
        do: assert(Keyword.has_key?(changeset.errors, field))
  end

  test "type changes preserve each type's separately saved model selection" do
    assert {:ok, agent} =
             AgentConfigs.create(%{
               name: "switchable",
               provider: "backplane",
               model: "text-model"
             })

    assert {:ok, voice} =
             AgentConfigs.update(agent, %{kind: "voice", voice_model: "openai/gpt-realtime"})

    assert voice.model == "text-model"
    assert {:ok, standard} = AgentConfigs.update(voice, %{kind: "standard"})
    assert standard.voice_model == "openai/gpt-realtime"
    assert standard.model == "text-model"
  end

  test "voice kinds select their own endpoint and preserve the other profile" do
    assert {:ok, voice} =
             AgentConfigs.create(%{
               name: "browser-voice",
               kind: :voice,
               provider: "backplane",
               voice_model: "openai/gpt-realtime",
               audio_mode: "host",
               host_audio_input_device: "host-mic",
               browser_audio_input_device: "web-mic"
             })

    assert AgentConfig.voice?(voice)
    refute AgentConfig.host?(voice)
    assert voice.audio_mode == "browser"
    assert {:ok, host} = AgentConfigs.update(voice, %{kind: :host_voice})
    assert AgentConfig.voice?(host)
    assert AgentConfig.host?(host)
    assert host.audio_mode == "host"
    assert host.host_audio_input_device == "host-mic"
    assert host.browser_audio_input_device == "web-mic"
  end

  test "Device Voice Agent uniqueness includes disabled configurations and concurrent creation" do
    attrs = %{kind: :host_voice, provider: "backplane", voice_model: "openai/gpt-realtime"}

    results =
      1..4
      |> Task.async_stream(fn index ->
        AgentConfigs.create(Map.put(attrs, :name, "host-#{index}"))
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, host}] = Enum.filter(results, &match?({:ok, _}, &1))

    for {:error, changeset} <- results do
      assert changeset.errors[:kind] == {"a Device Voice Agent already exists", []}
    end

    assert {:ok, _} = AgentConfigs.update(host, %{enabled: false})
    assert {:error, changeset} = AgentConfigs.create(Map.put(attrs, :name, "another-host"))
    assert Keyword.has_key?(changeset.errors, :kind)

    assert {:ok, voice} = AgentConfigs.create(Map.merge(attrs, %{name: "voice", kind: :voice}))
    assert {:error, changeset} = AgentConfigs.update(voice, %{kind: :host_voice})
    assert Keyword.has_key?(changeset.errors, :kind)
    assert AgentConfigs.get(voice.id).kind == :voice
  end

  test "direct config writes and TOML imports cannot add a second Device Voice Agent" do
    assert {:ok, host} =
             AgentConfigs.create(%{
               name: "host",
               kind: :host_voice,
               provider: "backplane",
               voice_model: "openai/gpt-realtime"
             })

    assert {:ok, raw} = Store.get(:agent, host.id)
    duplicate = Map.merge(raw, %{"id" => Ecto.UUID.generate(), "name" => "duplicate-host"})
    original = File.read!(Store.file_path(:agent))
    assert {:error, :host_agent_exists} = Store.put(:agent, duplicate)
    assert File.read!(Store.file_path(:agent)) == original

    assert {:ok, imported} = Formata.encode(%{"agents" => [raw, duplicate]}, :toml)
    File.write!(Store.file_path(:agent), imported)
    assert {:error, {:invalid_entry, :host_agent_exists}} = Store.reload(:agent)
    assert [saved] = AgentConfigs.list()
    assert saved.id == host.id
    File.write!(Store.file_path(:agent), original)
    assert :ok = Store.reload(:agent)
  end

  test "Device Voice Agent imports require a UUID identity" do
    raw = %{"id" => "host", "name" => "host", "kind" => "host_voice"}
    assert {:error, :invalid_host_agent_id} = Store.put(:agent, raw)

    assert {:error, :invalid_host_agent_id} =
             Store.put(:agent, %{raw | "id" => "1234567890abcdef"})

    assert {:ok, imported} = Formata.encode(%{"agents" => [raw]}, :toml)
    File.write!(Store.file_path(:agent), imported)
    assert {:error, {:invalid_entry, :invalid_host_agent_id}} = Store.reload(:agent)
    assert AgentConfigs.list() == []
    File.write!(Store.file_path(:agent), "")
    assert :ok = Store.reload(:agent)
  end

  test "invalid Device Voice Agent configuration survives a cold start and default seeding" do
    entries =
      for index <- 1..2 do
        %{"id" => Ecto.UUID.generate(), "name" => "host-#{index}", "kind" => "host_voice"}
      end

    assert {:ok, imported} = Formata.encode(%{"agents" => entries}, :toml)
    File.write!(Store.file_path(:agent), imported)
    supervisor = Synapsis.Config.Store.Supervisor
    child = {Synapsis.Config.Store.Server, :agent}
    assert :ok = Supervisor.terminate_child(supervisor, child)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, child)
    assert AgentConfigs.list() == []
    assert :ok = AgentConfigs.seed_defaults()
    assert File.read!(Store.file_path(:agent)) == imported
    assert {:error, :invalid_config} = Store.put(:agent, %{"id" => "main", "name" => "main"})
    assert File.read!(Store.file_path(:agent)) == imported

    File.write!(Store.file_path(:agent), "")
    assert :ok = Store.reload(:agent)
    assert :ok = AgentConfigs.seed_defaults()
    assert AgentConfigs.get_by_name("main")
  end
end
