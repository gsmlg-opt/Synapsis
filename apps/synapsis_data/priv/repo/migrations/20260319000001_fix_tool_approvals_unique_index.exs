defmodule Synapsis.Repo.Migrations.FixToolApprovalsUniqueIndex do
  use Ecto.Migration

  def change do
    # Drop the original index that doesn't handle NULL project_id correctly
    drop_if_exists(unique_index(:tool_approvals, [:scope, :project_id, :pattern]))

    # For project-scoped approvals (project_id IS NOT NULL)
    create(
      unique_index(:tool_approvals, [:scope, :project_id, :pattern],
        where: "project_id IS NOT NULL",
        name: :tool_approvals_scope_project_pattern_index
      )
    )

    # For global approvals (project_id IS NULL)
    create(
      unique_index(:tool_approvals, [:scope, :pattern],
        where: "project_id IS NULL",
        name: :tool_approvals_scope_pattern_global_index
      )
    )
  end
end
