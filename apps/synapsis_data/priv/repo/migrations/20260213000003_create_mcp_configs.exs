defmodule Synapsis.Repo.Migrations.CreateMCPConfigs do
  use Ecto.Migration

  def change do
    create table(:mcp_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :transport, :text, null: false, default: "stdio"
      add :command, :text
      add :args, :jsonb, default: "[]"
      add :url, :text
      add :env, :map, default: %{}
      add :auto_connect, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_configs, [:name])
  end
end
