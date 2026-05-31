defmodule Synapsis.Config.Store do
  @moduledoc """
  Public API for TOML-backed typed configuration.

  Configs live under the config directory (default `~/.config/synapsis/` or
  `$SYNAPSIS_CONFIG_DIR`) as TOML files, one per type:

      agents.toml   providers.toml   plugins.toml
      heartbeats.toml   toolsets.toml

  Reads are served from ETS (fast, concurrent). Writes persist to disk then
  update the ETS cache. FileSystem watches for out-of-band file edits and
  reloads within ~500 ms.

  This layer is additive — existing Ecto contexts continue to work until C4.
  """

  alias Synapsis.Config.Store.Server

  @types [:agent, :provider, :plugin, :heartbeat, :toolset]

  def types, do: @types

  @doc "List all entries for a type."
  @spec list(atom()) :: [map()]
  def list(type) when type in @types, do: Server.list(type)

  @doc "Get a single entry by id."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(type, id) when type in @types, do: Server.get(type, id)

  @doc "Upsert an entry. `attrs` must contain an `id` key."
  @spec put(atom(), map()) :: {:ok, map()} | {:error, term()}
  def put(type, attrs) when type in @types, do: Server.put(type, attrs)

  @doc "Delete an entry by id."
  @spec delete(atom(), String.t()) :: :ok
  def delete(type, id) when type in @types, do: Server.delete(type, id)

  @doc "Reload a type's entries from disk (also called automatically on file change)."
  @spec reload(atom()) :: :ok
  def reload(type) when type in @types, do: Server.reload(type)

  @doc "Config directory path."
  def config_dir do
    System.get_env("SYNAPSIS_CONFIG_DIR") ||
      Path.join(System.user_home!(), ".config/synapsis")
  end

  @doc "Path to the TOML file for a given type."
  def file_path(type) do
    name =
      case type do
        :agent -> "agents.toml"
        :provider -> "providers.toml"
        :plugin -> "plugins.toml"
        :heartbeat -> "heartbeats.toml"
        :toolset -> "toolsets.toml"
      end

    Path.join(config_dir(), name)
  end
end
