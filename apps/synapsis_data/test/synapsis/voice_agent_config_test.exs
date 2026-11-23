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
      kind: :voice,
      provider: "backplane",
      voice_model: "openai/gpt-realtime",
      voice: "marin",
      voice_turn_detection: "semantic_vad",
      audio_mode: "host",
      audio_input_device: "input-device",
      audio_output_device: "output-device",
      voice_delegate: "builder"
    }

    assert {:ok, agent} = AgentConfigs.create(attrs)
    assert :ok = Store.reload(:agent)
    saved = AgentConfigs.get(agent.id)
    for {field, value} <- attrs, do: assert(Map.get(saved, field) == value)
    assert {:ok, updated} = AgentConfigs.update(saved, %{audio_mode: "browser", voice: "cedar"})
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(agent.id) == updated
    assert {:ok, raw} = Store.get(:agent, agent.id)
    assert raw["kind"] == "voice"
    assert raw["voice_model"] == "openai/gpt-realtime"
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
end
