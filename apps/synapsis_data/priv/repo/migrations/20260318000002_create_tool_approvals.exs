defmodule Synapsis.Repo.Migrations.CreateToolApprovals do
  use Ecto.Migration

  def change do
    create table(:tool_approvals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:pattern, :string, null: false)
      add(:scope, :string, null: false)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all))
      add(:policy, :string, null: false)
      add(:created_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:tool_approvals, [:scope, :project_id, :pattern]))
    create(index(:tool_approvals, [:scope]))
    create(index(:tool_approvals, [:project_id]))
  end
end
