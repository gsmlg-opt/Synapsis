defmodule Synapsis.Repo.Migrations.CreateAgentSummaries do
  use Ecto.Migration

  def change do
    create table(:agent_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :scope_id, :string, null: false
      add :kind, :string, null: false
      add :content, :text, null: false
      add :metadata, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_summaries, [:scope, :scope_id, :kind])
  end
end
