defmodule Synapsis.ToolCall do
  @moduledoc """
  Tool invocation record (audit/replay).

  ADR-006 C4: an `embedded_schema` (no DB table). Tool calls are session-scoped
  data captured in the session's Concord turns / live process state; this struct
  is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:session_id, :binary_id)
    field(:message_id, :binary_id)

    field(:tool_name, :string)
    field(:input, :map)
    field(:output, :map)

    field(:status, Ecto.Enum,
      values: [:pending, :approved, :denied, :completed, :error],
      default: :pending
    )

    field(:duration_ms, :integer)
    field(:error_message, :string)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @required_fields ~w(session_id tool_name input)a
  @optional_fields ~w(id message_id output status duration_ms error_message)a

  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:tool_name, max: 255)
  end

  def complete_changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:output, :status, :duration_ms, :error_message])
    |> validate_inclusion(:status, [:completed, :error])
  end

  def approve_changeset(tool_call), do: change(tool_call, status: :approved)
  def deny_changeset(tool_call), do: change(tool_call, status: :denied)
end
