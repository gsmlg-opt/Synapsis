defmodule Synapsis.Repo.Migrations.RemoveRetiredDefaultAgents do
  use Ecto.Migration

  def up do
    execute("DELETE FROM agent_configs WHERE name IN ('assistant', 'build', 'plan')")
    execute("UPDATE agent_configs SET is_default = FALSE WHERE name <> 'main'")
    execute("UPDATE agent_configs SET is_default = TRUE WHERE name = 'main'")
    execute("UPDATE sessions SET agent = 'main' WHERE agent IN ('assistant', 'build', 'plan')")
  end

  def down do
    :ok
  end
end
