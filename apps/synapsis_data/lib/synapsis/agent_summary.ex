defmodule Synapsis.AgentSummary do
  @moduledoc """
  Summary rollup for agent/task/global scopes.

  ADR-006 C4: an `embedded_schema` (no DB table). Summaries are node-local
  coordination data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:scope, :string)
    field(:scope_id, :string)
    field(:kind, :string)
    field(:content, :string)
    field(:metadata, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @valid_scopes ~w(global agent task)

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:id, :scope, :scope_id, :kind, :content, :metadata])
    |> validate_required([:scope, :scope_id, :kind, :content])
    |> validate_inclusion(:scope, @valid_scopes)
  end
end
