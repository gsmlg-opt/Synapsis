defmodule Synapsis.ModelConfig do
  @moduledoc "A provider-linked model and its user-configured context window in tokens."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  embedded_schema do
    field(:provider_id, :binary_id)
    field(:model, :string)
    field(:name, :string)
    field(:context_window, :integer, default: 256_000)
    field(:enabled, :boolean, default: true)
    field(:input, {:array, :string}, default: nil)
    field(:selection_order, :integer)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :provider_id,
      :model,
      :name,
      :context_window,
      :enabled,
      :input,
      :selection_order
    ])
    |> validate_required([:provider_id, :model, :context_window, :enabled])
    |> validate_number(:context_window, greater_than: 0)
    |> validate_length(:model, max: 1024)
    |> validate_length(:name, max: 255)
  end
end
