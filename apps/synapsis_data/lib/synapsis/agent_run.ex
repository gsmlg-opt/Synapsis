defmodule Synapsis.AgentRun do
  @moduledoc "Persistent daemon run record for manual, heartbeat, dream, and scheduled work."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @kinds ~w(manual heartbeat dream schedule)
  @statuses ~w(queued running waiting_approval sleeping completed failed cancelled)
  @sources ~w(web system oban)
  @tool_profiles ~w(read_only reflect heartbeat coding maintenance dangerous)

  schema "agent_runs" do
    field(:kind, :string)
    field(:status, :string, default: "queued")
    field(:source, :string, default: "system")
    field(:assistant_name, :string)
    field(:session_id, :binary_id)
    field(:heartbeat_id, :binary_id)
    field(:routine_id, :binary_id)
    field(:prompt, :string)
    field(:tool_profile, :string, default: "read_only")
    field(:model, :string)
    field(:provider, :string)
    field(:summary, :string)
    field(:error, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :kind,
      :status,
      :source,
      :assistant_name,
      :session_id,
      :heartbeat_id,
      :routine_id,
      :prompt,
      :tool_profile,
      :model,
      :provider,
      :summary,
      :error,
      :started_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([:kind, :status, :source, :prompt, :tool_profile])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:tool_profile, @tool_profiles)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:heartbeat_id)
  end
end
