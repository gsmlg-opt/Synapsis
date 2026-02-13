defmodule Synapsis.Repo.Migrations.MigrateMcpLspToPluginConfigs do
  use Ecto.Migration

  def up do
    # Migrate MCP configs
    execute """
    INSERT INTO plugin_configs (id, type, name, transport, command, args, url, env, auto_start, scope, inserted_at, updated_at)
    SELECT id, 'mcp', name, transport, command, args, url, env, auto_connect, 'global', inserted_at, updated_at
    FROM mcp_configs
    ON CONFLICT DO NOTHING
    """

    # Migrate LSP configs
    execute """
    INSERT INTO plugin_configs (id, type, name, transport, command, args, root_path, settings, auto_start, scope, inserted_at, updated_at)
    SELECT id, 'lsp', language, 'stdio', command, args, root_path, settings, auto_start, 'project', inserted_at, updated_at
    FROM lsp_configs
    ON CONFLICT DO NOTHING
    """
  end

  def down do
    execute "DELETE FROM plugin_configs WHERE type IN ('mcp', 'lsp')"
  end
end
