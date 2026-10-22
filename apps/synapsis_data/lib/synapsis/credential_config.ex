defmodule Synapsis.CredentialConfig do
  @moduledoc "Safe metadata for a reusable encrypted API credential."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:name, :string)
    field(:masked_key, :string)
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "Validate submitted fields without adding secrets to the metadata schema."
  def changeset(data, attrs, opts \\ []) do
    {data, %{name: :string, key: :string}}
    |> cast(attrs, [:name, :key])
    |> validate_required(
      if(Keyword.get(opts, :require_key, false), do: [:name, :key], else: [:name])
    )
    |> validate_length(:name, max: 255)
  end
end
