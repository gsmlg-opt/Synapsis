defmodule Synapsis.Repo.Migrations.CreateSessionTodos do
  use Ecto.Migration

  def change do
    create table(:session_todos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :todo_id, :string, size: 255, null: false
      add :content, :text, null: false
      add :status, :string, size: 50, null: false, default: "pending"
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:session_todos, [:session_id])
    create unique_index(:session_todos, [:session_id, :todo_id])
  end
end
