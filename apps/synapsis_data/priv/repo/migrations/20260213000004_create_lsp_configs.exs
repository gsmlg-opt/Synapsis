defmodule Synapsis.Repo.Migrations.CreateLSPConfigs do
  use Ecto.Migration

  def change do
    create table(:lsp_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :language, :text, null: false
      add :command, :text, null: false
      add :args, :jsonb, default: "[]"
      add :root_path, :text
      add :auto_start, :boolean, null: false, default: true
      add :settings, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lsp_configs, [:language])
  end
end
