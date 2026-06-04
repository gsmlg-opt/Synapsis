defmodule Synapsis.FailedAttempt do
  @moduledoc """
  Records a failed approach during an agent session for loop prevention.

  ADR-006 C4: an `embedded_schema` (no DB table). The failure log is session-scoped
  Concord data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:attempt_number, :integer)
    field(:tool_call_hash, :string)
    field(:tool_calls_snapshot, :map, default: %{})
    field(:error_message, :string)
    field(:lesson, :string)
    field(:triggered_by, :string)
    field(:auditor_model, :string)
    field(:session_id, :binary_id)

    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(failed_attempt, attrs) do
    failed_attempt
    |> cast(attrs, [
      :id,
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
  end
end
