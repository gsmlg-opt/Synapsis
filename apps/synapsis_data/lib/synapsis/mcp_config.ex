defmodule Synapsis.MCPConfig do
  @moduledoc "Configuration for an MCP (Model Context Protocol) server."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_transports ~w(stdio sse)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "mcp_configs" do
    field :name, :string
    field :transport, :string, default: "stdio"
    field :command, :string
    field :args, {:array, :string}, default: []
    field :url, :string
    field :env, :map, default: %{}
    field :auto_connect, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mcp_config, attrs) do
    mcp_config
    |> cast(attrs, [:name, :transport, :command, :args, :url, :env, :auto_connect])
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, @valid_transports)
    |> unique_constraint(:name)
  end
end
