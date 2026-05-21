defmodule Synapsis.AgentConfig do
  @moduledoc "Schema for persisted agent configurations."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9_-]*$/
  @valid_model_tiers ~w(fast default expert)
  @valid_permission_modes ~w(yolo ask restrict)
  @valid_reasoning_efforts ~w(low medium high)

  schema "agent_configs" do
    field(:name, :string)
    field(:label, :string)
    field(:icon, :string, default: "robot-outline")
    field(:description, :string)
    field(:provider, :string)
    field(:model, :string)
    field(:system_prompt, :string)
    field(:tools, {:array, :string}, default: [])
    field(:reasoning_effort, :string, default: "medium")
    field(:read_only, :boolean, default: false)
    field(:max_tokens, :integer, default: 8192)
    field(:model_tier, :string, default: "default")
    field(:permission_mode, :string, default: "ask")
    field(:fallback_models, :string, default: "")
    field(:is_default, :boolean, default: false)
    field(:enabled, :boolean, default: true)
    field(:config, :map, default: %{})

    belongs_to(:toolset, Synapsis.Toolset)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(label icon description provider model system_prompt tools
                       reasoning_effort read_only max_tokens model_tier
                       permission_mode fallback_models is_default enabled config toolset_id)a

  def changeset(agent_config, attrs) do
    agent_config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_format,
      message:
        "must start with a letter or digit and contain only lowercase letters, digits, hyphens, or underscores"
    )
    |> validate_inclusion(:model_tier, @valid_model_tiers)
    |> validate_inclusion(:permission_mode, @valid_permission_modes)
    |> validate_inclusion(:reasoning_effort, @valid_reasoning_efforts)
    |> validate_number(:max_tokens, greater_than: 0)
    |> unique_constraint(:name)
  end

  def update_changeset(agent_config, attrs) do
    agent_config
    |> cast(attrs, @optional_fields)
    |> validate_inclusion(:model_tier, @valid_model_tiers)
    |> validate_inclusion(:permission_mode, @valid_permission_modes)
    |> validate_inclusion(:reasoning_effort, @valid_reasoning_efforts)
    |> validate_number(:max_tokens, greater_than: 0)
    |> unique_constraint(:name)
  end

  def valid_model_tiers, do: @valid_model_tiers
  def valid_permission_modes, do: @valid_permission_modes
  def valid_reasoning_efforts, do: @valid_reasoning_efforts
end
