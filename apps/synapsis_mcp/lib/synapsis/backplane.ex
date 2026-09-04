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
    :endpoint,
    :base_url,
    :credential,
    :connection_options,
    :sync_on_start,
    :enabled,
    :metadata,
    "name",
    "endpoint",
    "base_url",
    "credential",
    "connection_options",
    "sync_on_start",
    "enabled",
    "metadata"
  ]

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

    with {:ok, current} <- Connection.get(id),
         {:ok, updated} <- Connection.update(current, attrs) do
      reconcile_update(current, updated, attrs, opts)
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts \\ []) do
    with {:ok, connection} <- Connection.get(id),
         {:ok, _connection} <- set_available(id, false, opts) do
      Connection.delete(connection)
    end
  end

  @spec refresh(String.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def refresh(id, opts \\ []) do
    case Connection.get(id) do
      {:ok, %Connection{enabled: true}} -> sync(opts).run(id, sync_opts(opts))
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
      do: refresh_preserving(updated, opts),
      else: {:ok, updated}
  end

  defp reconcile_update(_current, updated, _attrs, _opts), do: {:ok, updated}

  defp source_changed?(current, updated) do
    current.name != updated.name or
      current.endpoint != updated.endpoint or
      current.credential != updated.credential or
      current.connection_options != updated.connection_options
  end

  defp refresh_preserving(connection, opts) do
    case refresh(connection.id, opts) do
      {:ok, %Connection{} = refreshed} -> {:ok, refreshed}
      :ok -> Connection.get(connection.id)
      {:error, _reason} -> Connection.get(connection.id)
      _unexpected -> Connection.get(connection.id)
    end
  end

  defp set_available(id, available?, opts) do
    case sync(opts).set_available(id, available?, sync_opts(opts)) do
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
        "tools" => length(snapshot.mcp_tools)
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
  defp editable_attrs(attrs) when is_map(attrs), do: Map.take(attrs, @editable_fields)
end
