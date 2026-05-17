defmodule Synapsis.Repo.Migrations.SetMainAgentAsOnlyDefault do
  use Ecto.Migration

  def up do
    execute("UPDATE agent_configs SET is_default = FALSE WHERE name <> 'main'")
    execute("UPDATE agent_configs SET is_default = TRUE WHERE name = 'main'")
  end

  def down do
    execute("UPDATE agent_configs SET is_default = FALSE WHERE name = 'main'")
    execute("UPDATE agent_configs SET is_default = TRUE WHERE name = 'build'")
  end
end
