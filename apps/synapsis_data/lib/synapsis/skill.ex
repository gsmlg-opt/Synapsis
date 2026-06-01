defmodule Synapsis.Skill do
  @moduledoc """
  A global skill definition assignable to agents.

  ADR-006 C4: an `embedded_schema` (no DB table). Skills persist in the
  file-backed `Config.Store` (`skills.toml`) via `Synapsis.Skills`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(global)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  embedded_schema do
    field(:scope, :string, default: "global")
    field(:name, :string)
    field(:description, :string)
    field(:system_prompt_fragment, :string)
    field(:tool_allowlist, {:array, :string}, default: [])
    field(:config_overrides, :map, default: %{})
    field(:is_builtin, :boolean, default: false)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :id,
      :scope,
      :name,
      :description,
      :system_prompt_fragment,
      :tool_allowlist,
      :config_overrides,
      :is_builtin
    ])
    |> validate_required([:scope, :name])
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_length(:name, max: 255)
    |> validate_length(:description, max: 2_000)
    |> validate_length(:system_prompt_fragment, max: 50_000)
  end
end
