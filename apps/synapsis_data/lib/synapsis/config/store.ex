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
  alias Synapsis.Config.ProviderCleanup
  require Logger

  @types [
    :agent,
    :provider,
    :credential,
    :model,
    :plugin,
    :heartbeat,
    :routine,
    :backplane,
    :toolset,
    :mcp,
    :lsp,
    :skill
  ]

  def types, do: @types

  @doc "List all entries for a type."
  @spec list(atom()) :: [map()]
  def list(type) when type in @types, do: Server.list(type)

  @doc "Get a single entry by id."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(type, id) when type in @types, do: Server.get(type, id)

  @doc "Upsert an entry. `attrs` must contain an `id` key."
  @spec put(atom(), map()) :: {:ok, map()} | {:error, term()}
  def put(type, attrs) when type in @types do
    with_write_lock(fn ->
      with :ok <- validate_references(type, attrs) do
        Server.put(type, attrs) |> notify_credential_change(type, [attrs[:id] || attrs["id"]])
      end
    end)
  end

  @doc "Merge fields into an existing entry without changing its stable ID or creating it."
  @spec merge_existing(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def merge_existing(type, id, attrs)
      when type in @types and is_binary(id) and is_map(attrs),
      do:
        with_write_lock(fn ->
          with {:ok, current} <- Server.get(type, id),
               merged = Map.merge(current, stringify_keys(attrs)),
               :ok <- validate_references(type, merged),
               do: Server.merge_existing(type, id, attrs) |> notify_credential_change(type, [id])
        end)

  @doc "Replace an existing entry completely, preserving its ID and rejecting missing entries."
  def replace_existing(type, id, attrs)
      when type in @types and is_binary(id) and is_map(attrs) do
    with_write_lock(fn ->
      with {:ok, _} <- Server.get(type, id),
           :ok <- validate_references(type, attrs),
           do: Server.replace_existing(type, id, attrs) |> notify_credential_change(type, [id])
    end)
  end

  @doc "Delete an entry by id."
  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(type, id) when type in @types do
    with_write_lock(fn ->
      with :ok <- validate_deletion(type, id) do
        Server.delete(type, id) |> notify_credential_change(type, [id])
      end
    end)
  end

  @doc "Delete a provider and its linked configuration, preserving historical sessions."
  def delete_provider(id), do: with_write_lock(fn -> ProviderCleanup.delete(id) end)

  @doc "Snapshot a provider's linked configuration before cleanup and runtime invalidation."
  def provider_dependencies(id), do: with_write_lock(fn -> ProviderCleanup.dependencies(id) end)

  @doc "Reload a type's entries from disk (also called automatically on file change)."
  @spec reload(atom()) :: :ok | {:error, term()}
  def reload(type) when type in @types do
    with_write_lock(fn ->
      old = if type == :credential, do: Map.new(Server.list(type), &{&1["id"], &1}), else: %{}
      result = Server.reload(type)
      current = if type == :credential, do: Map.new(Server.list(type), &{&1["id"], &1}), else: %{}

      changed_ids =
        (Map.keys(old) ++ Map.keys(current))
        |> Enum.uniq()
        |> Enum.filter(&(Map.get(old, &1) != Map.get(current, &1)))

      notify_credential_change(result, type, changed_ids)
    end)
  end

  @doc "Preserve existing configuration files in a private directory before migration."
  def backup(types, label) when is_list(types) and is_binary(label) do
    if Enum.all?(types, &(&1 in @types)) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/, label) do
      with_write_lock(fn -> backup_files(types, label) end)
    else
      {:error, :invalid_backup_request}
    end
  end

  def backup(_types, _label), do: {:error, :invalid_backup_request}

  defp backup_files(types, label) do
    root = Path.join(config_dir(), "backups")
    directory = Path.join(root, label <> "-" <> Ecto.UUID.generate())

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(directory) do
      result =
        with :ok <- File.chmod(directory, 0o700) do
          Enum.reduce_while(types, :ok, fn type, :ok ->
            case backup_file(file_path(type), directory) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end

      case result do
        :ok ->
          {:ok, directory}

        error ->
          File.rm_rf(directory)
          error
      end
    end
  end

  defp backup_file(source, directory) do
    case File.read(source) do
      {:ok, contents} ->
        destination = Path.join(directory, Path.basename(source))

        case File.open(destination, [:write, :exclusive, :binary], fn file ->
               with :ok <- File.chmod(destination, 0o600), do: IO.binwrite(file, contents)
             end) do
          {:ok, result} -> result
          error -> error
        end

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  @doc "Serialize configuration writes and their immediate registry updates on this node."
  def with_write_lock(fun) when is_function(fun, 0) do
    key = {__MODULE__, :write_lock_held}

    if Process.get(key, false) do
      fun.()
    else
      result =
        :global.trans(
          {{__MODULE__, :write}, self()},
          fn ->
            Process.put(key, true)

            try do
              result = fun.()
              {result, Process.get({__MODULE__, :credential_changes}, [])}
            after
              Process.delete(key)
              Process.delete({__MODULE__, :credential_changes})
            end
          end,
          [node()],
          10
        )

      case result do
        :aborted ->
          {:error, :config_write_lock_unavailable}

        {value, ids} ->
          dispatch_credential_changes(ids)
          value
      end
    end
  end

  defp validate_references(type, attrs) do
    attrs = stringify_keys(attrs)
    config = Map.get(attrs, if(type == :skill, do: "config_overrides", else: "config"), %{})
    source_id = if is_map(config), do: Map.get(config, "backplane_source_id")

    with :ok <- reference_exists(:provider, attrs["provider_id"]),
         :ok <- reference_exists(:backplane, source_id),
         :ok <-
           if(type == :provider,
             do: reference_exists(:credential, attrs["credential_id"]),
             else: :ok
           ),
         do: :ok
  end

  defp validate_deletion(:credential, id) do
    case Synapsis.Credentials.references(id) do
      [] -> :ok
      references -> {:error, {:in_use, references}}
    end
  end

  defp validate_deletion(_type, _id), do: :ok

  defp notify_credential_change(result, :credential, ids)
       when result == :ok or elem(result, 0) == :ok do
    key = {__MODULE__, :credential_changes}
    Process.put(key, Enum.uniq(Process.get(key, []) ++ Enum.reject(ids, &is_nil/1)))
    result
  end

  defp notify_credential_change(result, _type, _ids), do: result

  defp dispatch_credential_changes([]), do: :ok

  defp dispatch_credential_changes(ids) do
    case Application.get_env(:synapsis_data, :credential_change_callback) do
      callback when is_function(callback, 1) -> callback.(ids)
      _ -> :ok
    end
  rescue
    _ -> Logger.warning("credential_change_notification_failed")
  catch
    :exit, _ -> Logger.warning("credential_change_notification_failed")
  end

  defp reference_exists(_type, nil), do: :ok

  defp reference_exists(type, id) do
    case Server.get(type, id) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, {:missing_reference, type, id}}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key),
       if(is_map(value) and not is_struct(value), do: stringify_keys(value), else: value)}
    end)
  end

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
        :credential -> "credentials.toml"
        :model -> "models.toml"
        :plugin -> "plugins.toml"
        :heartbeat -> "heartbeats.toml"
        :routine -> "routines.toml"
        :backplane -> "backplanes.toml"
        :toolset -> "toolsets.toml"
        :mcp -> "mcp.toml"
        :lsp -> "lsp.toml"
        :skill -> "skills.toml"
      end

    Path.join(config_dir(), name)
  end
end
