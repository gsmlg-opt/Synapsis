defmodule Synapsis.HeartbeatConfig do
  @moduledoc """
  Schema for heartbeat configuration (AI-6).

  Heartbeats are scheduled agent invocations that run via Oban cron jobs.
  Each config defines a schedule, prompt, and behavior for proactive execution.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "heartbeat_configs" do
    field(:name, :string)
    field(:schedule, :string)
    field(:agent_type, Ecto.Enum, values: [:global, :project])
    field(:prompt, :string)
    field(:enabled, :boolean, default: false)
    field(:notify_user, :boolean, default: true)
    field(:session_isolation, Ecto.Enum, values: [:isolated, :main], default: :isolated)
    field(:keep_history, :boolean, default: false)

    belongs_to(:project, Synapsis.Project)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :name,
      :schedule,
      :agent_type,
      :project_id,
      :prompt,
      :enabled,
      :notify_user,
      :session_isolation,
      :keep_history
    ])
    |> validate_required([:name, :schedule, :prompt])
    |> validate_cron_expression(:schedule)
    |> unique_constraint(:name)
  end

  defp validate_cron_expression(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      parts = String.split(value, " ", trim: true)

      if length(parts) == 5 do
        []
      else
        [{field, "must be a valid cron expression with 5 fields"}]
      end
    end)
  end
end
