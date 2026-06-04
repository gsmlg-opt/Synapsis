defmodule Synapsis.LSPConfig do
  @moduledoc """
  Deprecated: Use `Synapsis.PluginConfig` with type "lsp" instead.

  ADR-006 C4: an `embedded_schema` (no DB table).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  embedded_schema do
    field(:language, :string)
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:root_path, :string)
    field(:auto_start, :boolean, default: true)
    field(:settings, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(lsp_config, attrs) do
    lsp_config
    |> cast(attrs, [:id, :language, :command, :args, :root_path, :auto_start, :settings])
    |> validate_required([:language, :command])
  end
end
