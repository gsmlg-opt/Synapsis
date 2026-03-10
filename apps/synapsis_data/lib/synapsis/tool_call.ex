defmodule Synapsis.ToolCall do
  @moduledoc "Persists tool invocations for audit and replay."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_calls" do
    belongs_to :session, Synapsis.Session
    belongs_to :message, Synapsis.Message

    field :tool_name, :string
    field :input, :map
    field :output, :map
    field :status, Ecto.Enum,
      values: [:pending, :approved, :denied, :completed, :error],
      default: :pending
    field :duration_ms, :integer
    field :error_message, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(session_id tool_name input)a
  @optional_fields ~w(message_id output status duration_ms error_message)a

  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:tool_name, max: 255)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:message_id)
  end

  def complete_changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:output, :status, :duration_ms, :error_message])
    |> validate_inclusion(:status, [:completed, :error])
  end

  def approve_changeset(tool_call) do
    change(tool_call, status: :approved)
  end

  def deny_changeset(tool_call) do
    change(tool_call, status: :denied)
  end
end
