defmodule Synapsis.Repo.Migrations.AddDebugToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :debug, :boolean, default: false, null: false
    end
  end
end
