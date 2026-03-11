defmodule Synapsis.Repo.Migrations.CreateToolCalls do
  use Ecto.Migration

  def change do
    create table(:tool_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :tool_name, :string, size: 255, null: false
      add :input, :map, null: false
      add :output, :map
      add :status, :string, size: 50, null: false, default: "pending"
      add :duration_ms, :integer
      add :error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_calls, [:session_id])
    create index(:tool_calls, [:session_id, :tool_name])
    create index(:tool_calls, [:session_id, :status])
  end
end
