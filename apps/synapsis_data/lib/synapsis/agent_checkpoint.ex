defmodule Synapsis.AgentCheckpoint do
  @moduledoc "Upsertable checkpoint for resumable graph execution."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_checkpoints" do
    field :run_id, :string
    field :graph, :map, default: %{}
    field :node, :string
    field :status, :string
    field :state, :map, default: %{}
    field :ctx, :map, default: %{}
    field :error, :map

    timestamps(type: :utc_datetime_usec)
  end

  @valid_statuses ~w(running waiting completed failed)

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:run_id, :graph, :node, :status, :state, :ctx, :error])
    |> validate_required([:run_id, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:run_id)
  end
end
