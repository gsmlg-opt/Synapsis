defmodule Synapsis.ProviderConfig do
  @moduledoc "Schema for persisted provider configurations."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_types ~w(anthropic openai openai_compat google local openrouter groq deepseek)
  @name_format ~r/^[a-z0-9][a-z0-9_-]*$/

  schema "provider_configs" do
    field :name, :string
    field :type, :string
    field :base_url, :string
    field :api_key_encrypted, Synapsis.Encrypted.Binary
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(provider_config, attrs) do
    provider_config
    |> cast(attrs, [:name, :type, :base_url, :api_key_encrypted, :config, :enabled])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @valid_types)
    |> validate_format(:name, @name_format, message: "must start with a letter or digit and contain only lowercase letters, digits, hyphens, or underscores")
    |> validate_base_url()
    |> unique_constraint(:name)
  end

  def update_changeset(provider_config, attrs) do
    provider_config
    |> cast(attrs, [:name, :type, :base_url, :api_key_encrypted, :config, :enabled])
    |> validate_inclusion(:type, @valid_types)
    |> validate_format(:name, @name_format, message: "must start with a letter or digit and contain only lowercase letters, digits, hyphens, or underscores")
    |> validate_base_url()
    |> unique_constraint(:name)
  end

  defp validate_base_url(changeset) do
    case get_change(changeset, :base_url) do
      nil ->
        changeset

      url ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          changeset
        else
          add_error(changeset, :base_url, "must be a valid HTTP or HTTPS URL")
        end
    end
  end

  def valid_types, do: @valid_types
end
