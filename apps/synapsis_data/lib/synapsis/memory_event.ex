defmodule Synapsis.MemoryEvent do
  @moduledoc "Append-only event log for memory system (Layer B: Episodic Memory)."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(shared project agent session)
  @valid_types ~w(
    run_created task_received plan_created plan_updated message_added
    tool_called tool_succeeded tool_failed handoff_requested handoff_completed
    human_feedback_received checkpoint_written task_completed task_failed
    run_paused run_resumed summary_created memory_promoted memory_updated memory_archived
  )

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_events" do
    field :scope, :string
    field :scope_id, :string
    field :agent_id, :string
    field :run_id, :string
    field :type, :string
    field :importance, :float, default: 0.5
    field :payload, :map, default: %{}
    field :causation_id, :string
    field :correlation_id, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(scope scope_id agent_id type)a
  @optional_fields ~w(run_id importance payload causation_id correlation_id)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_inclusion(:type, @valid_types)
    |> validate_number(:importance, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
