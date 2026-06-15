defmodule Synapsis.MCPConfig do
  @moduledoc """
  Configuration for a single MCP server (anubis_mcp client).

  Persisted in the file-backed `Config.Store` (`mcp.toml`). Embedded schema only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @valid_transports ~w(stdio streamable_http sse)

  @primary_key {:id, :binary_id, autogenerate: false}
  embedded_schema do
    field(:name, :string)
    field(:transport, :string, default: "stdio")
    field(:enabled, :boolean, default: true)
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:env, :map, default: %{})
    field(:url, :string)
    field(:headers, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:id, :name, :transport, :enabled, :command, :args, :env, :url, :headers])
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, @valid_transports)
    |> validate_length(:name, max: 255)
    |> validate_length(:command, max: 4_096)
    |> validate_length(:url, max: 2_048)
    |> validate_transport_fields()
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "stdio" -> validate_required(changeset, [:command])
      t when t in ["streamable_http", "sse"] -> validate_required(changeset, [:url])
      _ -> changeset
    end
  end
end
