defmodule Synapsis.Repo.Migrations.AddAgentPermissionModes do
  use Ecto.Migration

  def change do
    alter table(:agent_configs) do
      add(:permission_mode, :text, null: false, default: "ask")
    end

    alter table(:session_permissions) do
      add(:allow_read, :string, size: 50, null: false, default: "allow")
    end
  end
end
