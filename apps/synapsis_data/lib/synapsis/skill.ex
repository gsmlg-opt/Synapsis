defmodule Synapsis.Skill do
  @moduledoc "A skill definition scoped to global or project."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(global project)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "skills" do
    field :scope, :string, default: "global"
    field :name, :string
    field :description, :string
    field :system_prompt_fragment, :string
    field :tool_allowlist, {:array, :string}, default: []
    field :config_overrides, :map, default: %{}
    field :is_builtin, :boolean, default: false

    belongs_to :project, Synapsis.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:scope, :project_id, :name, :description, :system_prompt_fragment, :tool_allowlist, :config_overrides, :is_builtin])
    |> validate_required([:scope, :name])
    |> validate_inclusion(:scope, @valid_scopes)
    |> unique_constraint([:scope, :project_id, :name])
  end
end
