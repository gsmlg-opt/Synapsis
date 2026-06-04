defmodule Synapsis.AgentCheckpoint do
  @moduledoc """
  Checkpoint for resumable graph execution.

  ADR-006 C4: an `embedded_schema` (no DB table). Checkpoints are node-local
  Concord data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:run_id, :string)
    field(:graph, :map, default: %{})
    field(:node, :string)
    field(:status, :string)
    field(:state, :map, default: %{})
    field(:ctx, :map, default: %{})
    field(:error, :map)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @valid_statuses ~w(running waiting completed failed)

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:id, :run_id, :graph, :node, :status, :state, :ctx, :error])
    |> validate_required([:run_id, :status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
