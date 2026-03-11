defmodule Synapsis.SemanticMemory do
  @moduledoc "Stable, summarized, reusable knowledge (Layer D: Semantic Memory)."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(shared project agent)
  @valid_kinds ~w(fact decision lesson preference pattern warning summary policy)
  @valid_sources ~w(human summarizer agent)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "semantic_memories" do
    field :scope, :string
    field :scope_id, :string, default: ""
    field :kind, :string
    field :title, :string
    field :summary, :string
    field :detail, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :evidence_event_ids, {:array, :string}, default: []
    field :importance, :float, default: 0.5
    field :confidence, :float, default: 0.5
    field :freshness, :float, default: 1.0
    field :source, :string, default: "agent"
    field :contributed_by, :string
    field :access_count, :integer, default: 0
    field :last_accessed_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(scope kind title summary)a
  @optional_fields ~w(scope_id detail tags evidence_event_ids importance confidence freshness
                      source contributed_by access_count last_accessed_at archived_at)a

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_inclusion(:source, @valid_sources)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:freshness, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  def update_changeset(memory, attrs) do
    memory
    |> cast(attrs, ~w(title summary kind tags importance confidence archived_at)a)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
