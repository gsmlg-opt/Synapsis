defmodule Synapsis.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Oban removed in ADR-006 C3. Migration kept as a no-op so existing
  # deployments that have already run it don't fail on rollback/re-run.
  def up, do: :ok
  def down, do: :ok
end
