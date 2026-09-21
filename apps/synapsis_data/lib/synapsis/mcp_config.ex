defmodule Synapsis.MCPConfig do
  @moduledoc """
  Configuration for a single MCP server client.

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
    field(:config, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :id,
      :name,
      :transport,
      :enabled,
      :command,
      :args,
      :env,
      :url,
      :headers,
      :config
    ])
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, @valid_transports)
    |> validate_length(:name, max: 255)
    |> validate_length(:command, max: 4_096)
    |> validate_length(:url, max: 2_048)
    |> validate_change(:headers, &validate_headers/2)
    |> validate_transport_fields()
  end

  defp validate_headers(:headers, headers) do
    if Enum.all?(headers, fn {name, value} ->
         is_binary(name) and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) and
           is_binary(value) and not Regex.match?(~r/[\x00-\x08\x0A-\x1F\x7F]/, value)
       end) do
      []
    else
      [headers: "must contain valid HTTP header names and single-line string values"]
    end
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "stdio" -> validate_required(changeset, [:command])
      t when t in ["streamable_http", "sse"] -> validate_required(changeset, [:url])
      _ -> changeset
    end
  end
end
