defmodule Synapsis.PluginConfig do
  @moduledoc "Unified configuration for plugins (MCP, LSP, custom)."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(mcp lsp custom)
  @valid_transports ~w(stdio sse tcp)
  @valid_scopes ~w(global project)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "plugin_configs" do
    field :type, :string
    field :name, :string
    field :transport, :string, default: "stdio"
    field :command, :string
    field :args, {:array, :string}, default: []
    field :url, :string
    field :root_path, :string
    field :env, :map, default: %{}
    field :settings, :map, default: %{}
    field :auto_start, :boolean, default: false
    field :scope, :string, default: "project"

    belongs_to :project, Synapsis.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(plugin_config, attrs) do
    plugin_config
    |> cast(attrs, [
      :type,
      :name,
      :transport,
      :command,
      :args,
      :url,
      :root_path,
      :env,
      :settings,
      :auto_start,
      :scope,
      :project_id
    ])
    |> validate_required([:type, :name])
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:transport, @valid_transports)
    |> validate_inclusion(:scope, @valid_scopes)
    |> unique_constraint([:name, :scope, :project_id])
  end
end
