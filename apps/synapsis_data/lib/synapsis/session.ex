defmodule Synapsis.Session do
  @moduledoc "Session entity - a conversation workspace tied to a project."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field(:title, :string)
    field(:agent, :string, default: "build")
    field(:provider, :string)
    field(:model, :string)
    field(:status, :string, default: "idle")
    field(:config, :map, default: %{})
    field(:debug, :boolean, default: false)

    belongs_to(:project, Synapsis.Project)
    has_many(:messages, Synapsis.Message)
    has_many(:failed_attempts, Synapsis.FailedAttempt)
    has_many(:patches, Synapsis.Patch)
    has_many :tool_calls, Synapsis.ToolCall
    has_one :permission, Synapsis.SessionPermission
    has_many :todos, Synapsis.SessionTodo

    timestamps(type: :utc_datetime_usec)
  end

  @valid_statuses ~w(idle streaming tool_executing error)

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:title, :agent, :provider, :model, :status, :config, :project_id, :debug])
    |> validate_required([:provider, :model, :project_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:agent, min: 1, max: 255)
    |> foreign_key_constraint(:project_id)
  end

  def status_changeset(session, status) do
    session
    |> change(status: status)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
