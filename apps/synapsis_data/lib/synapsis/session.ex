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

    belongs_to(:project, Synapsis.Project)
    has_many(:messages, Synapsis.Message)
    has_many(:failed_attempts, Synapsis.FailedAttempt)
    has_many(:patches, Synapsis.Patch)

    timestamps(type: :utc_datetime_usec)
  end

  @valid_statuses ~w(idle streaming tool_executing error)
  @valid_agents ~w(build plan custom)

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:title, :agent, :provider, :model, :status, :config, :project_id])
    |> validate_required([:provider, :model, :project_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:agent, @valid_agents)
    |> foreign_key_constraint(:project_id)
  end

  def status_changeset(session, status) do
    session
    |> change(status: status)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
