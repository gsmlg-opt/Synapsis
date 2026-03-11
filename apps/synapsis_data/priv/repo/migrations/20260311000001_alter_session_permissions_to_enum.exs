defmodule Synapsis.Repo.Migrations.AlterSessionPermissionsToEnum do
  use Ecto.Migration

  def up do
    # Add temporary columns
    alter table(:session_permissions) do
      add :allow_write_new, :string, size: 50, null: false, default: "allow"
      add :allow_execute_new, :string, size: 50, null: false, default: "allow"
    end

    flush()

    # Migrate data: true -> "allow", false -> "deny"
    execute """
    UPDATE session_permissions
    SET allow_write_new = CASE WHEN allow_write = true THEN 'allow' ELSE 'deny' END,
        allow_execute_new = CASE WHEN allow_execute = true THEN 'allow' ELSE 'deny' END
    """

    # Drop old boolean columns
    alter table(:session_permissions) do
      remove :allow_write
      remove :allow_execute
    end

    # Rename new columns
    rename table(:session_permissions), :allow_write_new, to: :allow_write
    rename table(:session_permissions), :allow_execute_new, to: :allow_execute
  end

  def down do
    alter table(:session_permissions) do
      add :allow_write_old, :boolean, null: false, default: true
      add :allow_execute_old, :boolean, null: false, default: true
    end

    flush()

    execute """
    UPDATE session_permissions
    SET allow_write_old = CASE WHEN allow_write = 'allow' THEN true ELSE false END,
        allow_execute_old = CASE WHEN allow_execute = 'allow' THEN true ELSE false END
    """

    alter table(:session_permissions) do
      remove :allow_write
      remove :allow_execute
    end

    rename table(:session_permissions), :allow_write_old, to: :allow_write
    rename table(:session_permissions), :allow_execute_old, to: :allow_execute
  end
end
