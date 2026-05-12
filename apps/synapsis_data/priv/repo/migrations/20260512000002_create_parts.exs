defmodule Synapsis.Repo.Migrations.CreateParts do
  use Ecto.Migration

  def change do
    create table(:parts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:ordinal, :integer, null: false)
      add(:type, :text, null: false)
      add(:data, :map, null: false, default: %{})
      add(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:parts, [:message_id, :ordinal]))
    create(index(:parts, [:session_id, :inserted_at]))
    create(index(:parts, [:type]))
  end
end
