defmodule Synapsis.Repo.Migrations.CreateAgentMessages do
  use Ecto.Migration

  def change do
    create table(:agent_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:ref, :string, null: false)
      add(:from_agent_id, :string, null: false)
      add(:to_agent_id, :string, null: false)

      add(:type, :string,
        null: false,
        default: "notification"
      )

      add(:in_reply_to, references(:agent_messages, type: :binary_id, on_delete: :nilify_all))
      add(:payload, :map, default: %{})

      add(:status, :string,
        null: false,
        default: "delivered"
      )

      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all))
      add(:expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:agent_messages, [:to_agent_id, :inserted_at]))
    create(index(:agent_messages, [:from_agent_id, :inserted_at]))
    create(index(:agent_messages, [:ref]))
    create(index(:agent_messages, [:in_reply_to]))
    create(index(:agent_messages, [:project_id, :inserted_at]))
    create(index(:agent_messages, [:type]))
    create(index(:agent_messages, [:status]))
  end
end
