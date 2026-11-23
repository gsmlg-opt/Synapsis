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

  embedded_schema do
    field(:name, :string)
    field(:label, :string)
    field(:icon, :string, default: "robot-outline")
    field(:description, :string)
    field(:kind, Ecto.Enum, values: [:standard, :voice], default: :standard)
    field(:provider, :string)
    field(:model, :string)
    field(:voice_model, :string)
    field(:voice, :string, default: "marin")
    field(:voice_turn_detection, :string, default: "server_vad")
    field(:audio_mode, :string, default: "browser")
    field(:audio_input_device, :string)
    field(:audio_output_device, :string)
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
                       audio_mode audio_input_device audio_output_device voice_delegate system_prompt tools tool_contract_version
                       reasoning_effort read_only max_tokens model_tier
                       permission_mode fallback_models is_default enabled config toolset_id toolset_ids)a

  def changeset(agent_config, attrs) do
    agent_config
    |> cast(attrs, @required_fields ++ @optional_fields)
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
    |> cast(attrs, @optional_fields)
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
      |> validate_length(:audio_input_device, max: 512)
      |> validate_length(:audio_output_device, max: 512)
      |> validate_format(:voice_delegate, @name_format)

    if get_field(changeset, :kind) == :voice do
      changeset
      |> validate_required([:provider, :voice_model, :voice, :voice_turn_detection, :audio_mode])
      |> validate_length(:voice_model, max: 256)
      |> validate_format(:voice_model, ~r/\A[^\s\/]+\/[^\s]+\z/,
        message: "must be a qualified Realtime provider/model"
      )
    else
      changeset
    end
  end

  def valid_model_tiers, do: @valid_model_tiers
  def valid_permission_modes, do: @valid_permission_modes
  def valid_reasoning_efforts, do: @valid_reasoning_efforts
  def valid_voices, do: @valid_voices
  def valid_turn_detection, do: @valid_turn_detection
  def valid_audio_modes, do: @valid_audio_modes
end
