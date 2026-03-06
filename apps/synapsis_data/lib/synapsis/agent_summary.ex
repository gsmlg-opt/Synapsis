defmodule Synapsis.AgentSummary do
  @moduledoc "Upsertable summary for project/task/global rollups."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_summaries" do
    field :scope, :string
    field :scope_id, :string
    field :kind, :string
    field :content, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @valid_scopes ~w(global project task)

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:scope, :scope_id, :kind, :content, :metadata])
    |> validate_required([:scope, :scope_id, :kind, :content])
    |> validate_inclusion(:scope, @valid_scopes)
    |> unique_constraint([:scope, :scope_id, :kind])
  end
end
