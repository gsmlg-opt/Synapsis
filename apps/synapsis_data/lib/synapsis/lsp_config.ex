defmodule Synapsis.LSPConfig do
  @moduledoc "Configuration for a Language Server Protocol server."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "lsp_configs" do
    field :language, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :root_path, :string
    field :auto_start, :boolean, default: true
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lsp_config, attrs) do
    lsp_config
    |> cast(attrs, [:language, :command, :args, :root_path, :auto_start, :settings])
    |> validate_required([:language, :command])
    |> unique_constraint(:language)
  end
end
