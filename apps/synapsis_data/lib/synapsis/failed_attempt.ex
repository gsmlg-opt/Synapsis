defmodule Synapsis.FailedAttempt do
  @moduledoc "Records a failed approach during an agent session for loop prevention."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "failed_attempts" do
    field(:attempt_number, :integer)
    field(:tool_call_hash, :string)
    field(:tool_calls_snapshot, :map, default: %{})
    field(:error_message, :string)
    field(:lesson, :string)
    field(:triggered_by, :string)
    field(:auditor_model, :string)

    belongs_to(:session, Synapsis.Session)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(failed_attempt, attrs) do
    failed_attempt
    |> cast(attrs, [
      :session_id,
      :attempt_number,
      :tool_call_hash,
      :tool_calls_snapshot,
      :error_message,
      :lesson,
      :triggered_by,
      :auditor_model
    ])
    |> validate_required([:session_id, :attempt_number])
    |> foreign_key_constraint(:session_id)
  end
end
