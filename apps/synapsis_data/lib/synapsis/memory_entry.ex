defmodule Synapsis.MemoryEntry do
  @moduledoc "A memory entry scoped to global, project, or session."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(global project session)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memory_entries" do
    field :scope, :string
    field :scope_id, :binary_id
    field :key, :string
    field :content, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(memory_entry, attrs) do
    memory_entry
    |> cast(attrs, [:scope, :scope_id, :key, :content, :metadata])
    |> validate_required([:scope, :key, :content])
    |> validate_inclusion(:scope, @valid_scopes)
    |> unique_constraint([:scope, :scope_id, :key])
  end
end
