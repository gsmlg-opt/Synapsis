defmodule Synapsis.AgentConfig do
  @moduledoc """
  Agent configuration entity.

  ADR-006 C4: an `embedded_schema` (no DB table). Agent configs persist in the
  file-backed `Config.Store` (`agents.toml`) via `Synapsis.AgentConfigs`; this
  struct is the in-memory shape and changeset/validation surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9_-]*$/
  @valid_model_tiers ~w(fast default expert)
  @valid_permission_modes ~w(yolo ask restrict)
  @valid_reasoning_efforts ~w(low medium high)
  @valid_voices ~w(alloy ash ballad coral echo sage shimmer verse marin cedar)
  @valid_turn_detection ~w(server_vad semantic_vad manual)
  @valid_audio_modes ~w(host browser)
  @audio_fields %{
    "host" => [
      input_device: :host_audio_input_device,
      output_device: :host_audio_output_device,
      input_volume: :host_audio_input_volume,
      output_volume: :host_audio_output_volume
    ],
    "browser" => [
      input_device: :browser_audio_input_device,
      output_device: :browser_audio_output_device,
      input_volume: :browser_audio_input_volume,
      output_volume: :browser_audio_output_volume
    ]
  }
  @legacy_audio_fields [
    input_device: :audio_input_device,
    output_device: :audio_output_device,
    input_volume: :audio_input_volume,
    output_volume: :audio_output_volume
  ]

  embedded_schema do
    field(:name, :string)
    field(:label, :string)
    field(:icon, :string, default: "robot-outline")
    field(:description, :string)
    field(:kind, Ecto.Enum, values: [:standard, :voice, :host_voice], default: :standard)
    field(:provider, :string)
    field(:model, :string)
    field(:voice_model, :string)
    field(:voice, :string, default: "marin")
    field(:voice_turn_detection, :string, default: "server_vad")
    field(:audio_mode, :string, default: "browser")
    field(:host_audio_input_device, :string)
    field(:host_audio_output_device, :string)
    field(:host_audio_input_volume, :integer)
    field(:host_audio_output_volume, :integer)
    field(:browser_audio_input_device, :string)
    field(:browser_audio_output_device, :string)
    field(:browser_audio_input_volume, :integer)
    field(:browser_audio_output_volume, :integer)
    field(:voice_delegate, :string)
    field(:system_prompt, :string)
    field(:tools, {:array, :string}, default: [])
    field(:tool_contract_version, :integer, default: 0)
    field(:reasoning_effort, :string, default: "medium")
    field(:read_only, :boolean, default: false)
    field(:max_tokens, :integer, default: 8192)
    field(:model_tier, :string, default: "default")
    field(:permission_mode, :string, default: "yolo")
    field(:fallback_models, :string, default: "")
    field(:is_default, :boolean, default: false)
    field(:enabled, :boolean, default: true)
    field(:config, :map, default: %{})
    field(:toolset_ids, {:array, :string}, default: [])
    field(:toolset_id, :binary_id)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(id label icon description kind provider model voice_model voice voice_turn_detection
                       audio_mode host_audio_input_device host_audio_output_device host_audio_input_volume host_audio_output_volume
                       browser_audio_input_device browser_audio_output_device browser_audio_input_volume browser_audio_output_volume
                       voice_delegate system_prompt tools tool_contract_version
                       reasoning_effort read_only max_tokens model_tier
                       permission_mode fallback_models is_default enabled config toolset_id toolset_ids)a

  def changeset(agent_config, attrs) do
    agent_config
    |> cast(
      migrate_audio_attrs(attrs, agent_config.audio_mode),
      @required_fields ++ @optional_fields
    )
    |> validate_required(@required_fields)
    |> validate_required([:tool_contract_version])
    |> validate_inclusion(:tool_contract_version, [0, 1])
    |> validate_format(:name, @name_format,
      message:
        "must start with a letter or digit and contain only lowercase letters, digits, hyphens, or underscores"
    )
    |> validate_inclusion(:model_tier, @valid_model_tiers)
    |> validate_inclusion(:permission_mode, @valid_permission_modes)
    |> validate_inclusion(:reasoning_effort, @valid_reasoning_efforts)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_voice()
  end

  def update_changeset(agent_config, attrs) do
    agent_config
    |> cast(migrate_audio_attrs(attrs, agent_config.audio_mode), @optional_fields)
    |> validate_required([:tool_contract_version])
    |> validate_inclusion(:tool_contract_version, [0, 1])
    |> validate_inclusion(:model_tier, @valid_model_tiers)
    |> validate_inclusion(:permission_mode, @valid_permission_modes)
    |> validate_inclusion(:reasoning_effort, @valid_reasoning_efforts)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_voice()
  end

  defp validate_voice(changeset) do
    changeset =
      changeset
      |> validate_required([:kind])
      |> validate_inclusion(:voice, @valid_voices)
      |> validate_inclusion(:voice_turn_detection, @valid_turn_detection)
      |> validate_inclusion(:audio_mode, @valid_audio_modes)
      |> validate_audio_profiles()
      |> validate_format(:voice_delegate, @name_format)

    if get_field(changeset, :kind) in [:voice, :host_voice] do
      changeset
      |> put_change(
        :audio_mode,
        if(get_field(changeset, :kind) == :host_voice, do: "host", else: "browser")
      )
      |> validate_required([:provider, :voice_model, :voice, :voice_turn_detection, :audio_mode])
      |> validate_length(:voice_model, max: 256)
      |> validate_format(:voice_model, ~r/\A[^\s\/]+\/[^\s]+\z/,
        message: "must be a qualified Realtime provider/model"
      )
    else
      changeset
    end
  end

  defp validate_audio_profiles(changeset) do
    Enum.reduce(@audio_fields, changeset, fn {mode, fields}, acc ->
      maximum = max_audio_volume(mode)

      acc
      |> validate_length(fields[:input_device], max: 512)
      |> validate_length(fields[:output_device], max: 512)
      |> validate_number(fields[:input_volume],
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: maximum
      )
      |> validate_number(fields[:output_volume],
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: maximum
      )
    end)
  end

  def audio_fields(mode), do: Map.fetch!(@audio_fields, mode)
  def voice?(%__MODULE__{kind: kind}), do: kind in [:voice, :host_voice]
  def host?(%__MODULE__{kind: :host_voice}), do: true
  def host?(%__MODULE__{}), do: false
  def max_audio_volume("host"), do: 150
  def max_audio_volume("browser"), do: 200

  def audio_profiles(%__MODULE__{} = agent) do
    Map.new(@audio_fields, fn {mode, fields} ->
      {mode, Map.new(fields, fn {key, field} -> {key, Map.fetch!(agent, field)} end)}
    end)
  end

  def migrate_audio_attrs(attrs, fallback_mode \\ "browser") do
    key =
      if Map.has_key?(attrs, "name") or Enum.any?(Map.keys(attrs), &is_binary/1),
        do: &Atom.to_string/1,
        else: &Function.identity/1

    mode = Map.get(attrs, key.(:audio_mode), fallback_mode)
    fields = Map.get(@audio_fields, mode, [])

    attrs =
      Enum.reduce(@legacy_audio_fields, attrs, fn {name, field}, acc ->
        case Map.pop(acc, key.(field)) do
          {nil, acc} -> acc
          {value, acc} when fields != [] -> Map.put_new(acc, key.(fields[name]), value)
          {_value, acc} -> acc
        end
      end)

    browser_speaker = key.(:browser_audio_output_device)
    if attrs[browser_speaker] == "default", do: Map.put(attrs, browser_speaker, nil), else: attrs
  end

  def valid_model_tiers, do: @valid_model_tiers
  def valid_permission_modes, do: @valid_permission_modes
  def valid_reasoning_efforts, do: @valid_reasoning_efforts
  def valid_voices, do: @valid_voices
  def valid_turn_detection, do: @valid_turn_detection
  def valid_audio_modes, do: @valid_audio_modes
end
