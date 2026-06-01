defmodule Synapsis.MCPConfig do
  @moduledoc """
  Deprecated: Use `Synapsis.PluginConfig` with type "mcp" instead.

  ADR-006 C4: an `embedded_schema` (no DB table).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_transports ~w(stdio http sse)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  embedded_schema do
    field(:name, :string)
    field(:transport, :string, default: "stdio")
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:url, :string)
    field(:env, :map, default: %{})
    field(:auto_connect, :boolean, default: false)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(mcp_config, attrs) do
    mcp_config
    |> cast(attrs, [:id, :name, :transport, :command, :args, :url, :env, :auto_connect])
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, @valid_transports)
  end
end
