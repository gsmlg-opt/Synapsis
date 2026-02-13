defmodule Synapsis.Repo.Migrations.CreateProviderConfigs do
  use Ecto.Migration

  def change do
    create table(:provider_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :type, :text, null: false
      add :base_url, :text
      add :api_key_encrypted, :binary
      add :config, :map, default: %{}
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_configs, [:name])
    create index(:provider_configs, [:type])
    create index(:provider_configs, [:enabled])
  end
end
