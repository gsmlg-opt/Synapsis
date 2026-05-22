defmodule Synapsis.Repo.Migrations.RemoveProjectsForAgentOwnedSessions do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      table_names text[] := ARRAY[
        'parts',
        'messages',
        'tool_calls',
        'session_permissions',
        'session_todos',
        'failed_attempts',
        'patches',
        'agent_checkpoints',
        'agent_summaries',
        'harness_events',
        'memory_checkpoints',
        'memory_entries',
        'memory_events',
        'semantic_memories',
        'workspace_document_versions',
        'workspace_documents',
        'agent_events',
        'agent_messages',
        'agent_runs',
        'repo_worktrees',
        'repo_remotes',
        'repos',
        'sessions',
        'projects'
      ];
      existing_tables text;
    BEGIN
      SELECT string_agg(format('%I', table_name), ', ')
      INTO existing_tables
      FROM unnest(table_names) AS table_name
      WHERE to_regclass(table_name) IS NOT NULL;

      IF existing_tables IS NOT NULL THEN
        EXECUTE 'TRUNCATE TABLE ' || existing_tables || ' RESTART IDENTITY CASCADE';
      END IF;
    END $$;
    """)

    alter table(:sessions) do
      remove(:project_id)
    end

    alter table(:skills) do
      remove(:project_id)
    end

    execute("UPDATE skills SET scope = 'global' WHERE scope = 'project'")
    create(unique_index(:skills, [:scope, :name]))

    alter table(:plugin_configs) do
      remove(:project_id)
      modify(:scope, :string, default: "global")
    end

    execute("UPDATE plugin_configs SET scope = 'global' WHERE scope = 'project'")
    create(unique_index(:plugin_configs, [:name, :scope]))

    drop_if_exists(
      unique_index(:tool_approvals, [:scope, :project_id, :pattern],
        name: :tool_approvals_scope_project_pattern_index
      )
    )

    drop_if_exists(
      unique_index(:tool_approvals, [:scope, :pattern],
        name: :tool_approvals_scope_pattern_global_index
      )
    )

    alter table(:tool_approvals) do
      remove(:project_id)
      add(:agent_name, :string)
    end

    execute("UPDATE tool_approvals SET scope = 'global' WHERE scope = 'project'")

    create(
      unique_index(:tool_approvals, [:scope, :agent_name, :pattern],
        where: "agent_name IS NOT NULL",
        name: :tool_approvals_scope_agent_pattern_index
      )
    )

    create(
      unique_index(:tool_approvals, [:scope, :pattern],
        where: "agent_name IS NULL",
        name: :tool_approvals_scope_pattern_global_index
      )
    )

    create(index(:tool_approvals, [:agent_name]))

    alter table(:workspace_documents) do
      remove(:project_id)
      add(:agent_id, :string)
    end

    create(index(:workspace_documents, [:agent_id]))

    execute("ALTER TYPE workspace_visibility ADD VALUE IF NOT EXISTS 'agent_shared'")

    alter table(:agent_messages) do
      remove(:project_id)
    end

    alter table(:agent_events) do
      remove(:project_id)
      add(:agent_id, :string)
    end

    create(index(:agent_events, [:agent_id]))

    alter table(:agent_runs) do
      remove(:project_id)
    end

    alter table(:heartbeat_configs) do
      remove(:project_id)
      add(:agent_name, :string)
    end

    create(index(:heartbeat_configs, [:agent_name]))

    execute("UPDATE heartbeat_configs SET agent_type = 'global' WHERE agent_type = 'project'")

    drop(table(:repo_worktrees))
    drop(table(:repo_remotes))
    drop(table(:repos))
    drop(table(:projects))
  end

  def down do
    raise "destructive reset migration is irreversible"
  end
end
