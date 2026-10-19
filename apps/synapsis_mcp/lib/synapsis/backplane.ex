defmodule Synapsis.Backplane do
  @moduledoc """
  Lifecycle facade for persisted Backplane capability sources.

  Connection persistence stays independent from discovery so an unreachable
  source never erases the saved connection or its last-known-good artifacts.
  """

  alias Synapsis.Backplane.{Client, Connection, Snapshot, Sync}

  @default_discovery_timeout 5_000
  @max_error_length 500
  @editable_fields [
    :name,
    :provider_id,
    :endpoint,
    :base_url,
    :credential,
    :connection_options,
    :sync_on_start,
    :enabled,
    :metadata,
    "name",
    "provider_id",
    "endpoint",
    "base_url",
    "credential",
    "connection_options",
    "sync_on_start",
    "enabled",
    "metadata"
  ]

  @doc "Explicitly enable a provider-backed capability source without performing remote I/O."
  def select_provider(provider_id, surface) when surface in ["skills", "tools"] do
    with {:ok, resolved} <- Synapsis.Backplane.ProviderSource.get(provider_id),
         true <- Synapsis.Backplane.ProviderSource.backplane?(resolved.provider) do
      case Enum.find(Connection.list(), &(&1.provider_id == provider_id)) do
        nil ->
          Connection.create(%{
            name: "provider-" <> provider_id,
            provider_id: provider_id,
            connection_options: %{"enabled_surfaces" => [surface]}
          })

        source ->
          surfaces =
            source.connection_options["enabled_surfaces"] || ["models", "tools", "skills"]

          Connection.update(source, %{
            connection_options:
              Map.put(
                source.connection_options,
                "enabled_surfaces",
                Enum.uniq(surfaces ++ [surface])
              )
          })
      end
    else
      _ -> {:error, :provider_unavailable}
    end
  end

  def select_mcp_provider(provider_id, override \\ nil) do
    with {:ok, source} <- select_provider(provider_id, "tools") do
      overridden? = is_binary(override) and String.trim(override) != ""
      url = if overridden?, do: String.trim(override), else: source.endpoint <> "/mcp"

      options =
        if overridden?,
          do: Map.put(source.connection_options, "mcp_url", url),
          else: Map.delete(source.connection_options, "mcp_url")

      with {:ok, source} <- Connection.update(source, %{connection_options: options}) do
        attrs = %{
          provider_id: provider_id,
          name: "backplane-" <> source.id,
          transport: "streamable_http",
          url: url,
          config: %{
            "managed_by" => "backplane",
            "source" => "backplane",
            "backplane_source_id" => source.id,
            "kind" => "mcp_server",
            "external_id" => "mcp",
            "backplane_available" => true,
            "provider_url_override" => overridden?
          }
        }

        case Enum.find(
               Synapsis.MCPConfigs.list(),
               &(&1.config["backplane_source_id"] == source.id)
             ) do
          nil -> Synapsis.MCPConfigs.create(attrs)
          config -> Synapsis.MCPConfigs.update(config, Map.delete(attrs, :name))
        end
      end
    end
  end

  @spec list() :: [Connection.t()]
  def list, do: Connection.list()

  @spec get(String.t()) :: {:ok, Connection.t()} | {:error, :not_found}
  def get(id), do: Connection.get(id)

  @spec status(String.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def status(id, opts \\ []), do: sync(opts).status(id)

  @spec create(map(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def create(attrs, opts \\ []) do
    with {:ok, connection} <- Connection.create(editable_attrs(attrs)) do
      if connection.enabled, do: refresh_preserving(connection, opts), else: {:ok, connection}
    end
  end

  @spec update(String.t(), map(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def update(id, attrs, opts \\ []) do
    attrs = editable_attrs(attrs)
    Sync.with_lock(id, sync_opts(opts), fn -> update_locked(id, attrs, opts) end)
  end

  defp update_locked(id, attrs, opts) do
    with {:ok, current} <- Connection.get(id),
         {:ok, updated} <- Connection.update(current, attrs) do
      reconcile_update(current, updated, attrs, opts)
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts \\ []) do
    Sync.with_lock(id, sync_opts(opts), fn -> delete_locked(id, opts) end)
  end

  defp delete_locked(id, opts) do
    with {:ok, connection} <- Connection.get(id),
         {:ok, connection} <- disable_before_delete(connection),
         {:ok, _connection} <- set_available(id, false, opts) do
      Connection.delete(connection)
    end
  end

  defp disable_before_delete(%Connection{enabled: false} = connection), do: {:ok, connection}

  defp disable_before_delete(%Connection{} = connection) do
    Connection.update(connection, %{enabled: false})
  end

  @spec refresh(String.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def refresh(id, opts \\ []) do
    Sync.with_lock(id, sync_opts(opts), fn -> refresh_locked(id, opts) end)
  end

  defp refresh_locked(id, opts) do
    case Connection.get(id) do
      {:ok, %Connection{enabled: true}} -> sync(opts).run(id, locked_sync_opts(opts))
      {:ok, %Connection{enabled: false}} -> {:error, :connection_disabled}
      {:error, _reason} = error -> error
    end
  end

  @spec test(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | {:discovery_failed, map()} | term()}
  def test(id, opts \\ []) do
    with {:ok, connection} <- Connection.get(id),
         {:ok, %Snapshot{} = snapshot} <-
           client(opts).fetch_snapshot(connection, client_opts(opts)) do
      result = summarize(snapshot, connection.credential)

      if map_size(result.errors) == 0,
        do: {:ok, result},
        else: {:error, {:discovery_failed, result}}
    end
  end

  defp reconcile_update(_current, %Connection{enabled: false} = updated, attrs, opts)
       when is_map(attrs) do
    if Map.get(attrs, :enabled, Map.get(attrs, "enabled")) == false,
      do: set_available(updated.id, false, opts),
      else: {:ok, updated}
  end

  defp reconcile_update(current, %Connection{enabled: true} = updated, _attrs, opts) do
    if not current.enabled or source_changed?(current, updated),
      do: refresh_preserving(updated, opts, true),
      else: {:ok, updated}
  end

  defp reconcile_update(_current, updated, _attrs, _opts), do: {:ok, updated}

  defp source_changed?(current, updated) do
    current.name != updated.name or
      current.endpoint != updated.endpoint or
      current.credential != updated.credential or
      current.connection_options != updated.connection_options
  end

  defp refresh_preserving(connection, opts, already_locked \\ false) do
    result =
      if already_locked,
        do: refresh_locked(connection.id, opts),
        else: refresh(connection.id, opts)

    case result do
      {:ok, %Connection{} = refreshed} -> {:ok, refreshed}
      :ok -> Connection.get(connection.id)
      {:error, _reason} -> Connection.get(connection.id)
      _unexpected -> Connection.get(connection.id)
    end
  end

  defp set_available(id, available?, opts) do
    case sync(opts).set_available(id, available?, locked_sync_opts(opts)) do
      {:ok, %Connection{} = connection} -> {:ok, connection}
      :ok -> Connection.get(id)
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_sync_result, other}}
    end
  end

  defp summarize(snapshot, credential) do
    errors =
      Map.new(snapshot.errors, fn {surface, reason} ->
        {surface_name(surface), safe_error(reason, credential)}
      end)

    %{
      status: if(map_size(errors) == 0, do: "ok", else: "error"),
      counts: %{
        "models" => length(snapshot.models),
        "skills" => length(snapshot.skills),
        "tools" => length(snapshot.mcp_tools),
        "other_capabilities" => length(snapshot.other_capabilities)
      },
      errors: errors
    }
  end

  defp safe_error(reason, credential) do
    message = inspect(reason, limit: 20, printable_limit: @max_error_length)

    message =
      if is_binary(credential) and credential != "",
        do: String.replace(message, credential, "[REDACTED]"),
        else: message

    String.slice(message, 0, @max_error_length)
  end

  defp client_opts(opts) do
    opts
    |> Keyword.get(:client_opts, [])
    |> Keyword.put_new(:timeout, @default_discovery_timeout)
  end

  defp surface_name(:mcp_tools), do: "tools"
  defp surface_name(surface), do: to_string(surface)

  defp client(opts), do: Keyword.get(opts, :client, Client)
  defp sync(opts), do: Keyword.get(opts, :sync, Sync)
  defp sync_opts(opts), do: Keyword.get(opts, :sync_opts, [])
  defp locked_sync_opts(opts), do: Keyword.put(sync_opts(opts), :already_locked, true)
  defp editable_attrs(attrs) when is_map(attrs), do: Map.take(attrs, @editable_fields)
end
