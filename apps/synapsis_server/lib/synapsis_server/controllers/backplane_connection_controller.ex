defmodule SynapsisServer.BackplaneConnectionController do
  use SynapsisServer, :controller

  alias Synapsis.Backplane

  @max_error_length 500

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Backplane.list(), &serialize/1)})
  end

  def create(conn, params) do
    case Backplane.create(params) do
      {:ok, connection} ->
        conn |> put_status(:created) |> json(%{data: serialize(connection)})

      {:error, reason} ->
        connection_error(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Backplane.update(id, Map.delete(params, "id")) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Backplane.delete(id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def status(conn, %{"id" => id}) do
    case Backplane.status(id) do
      {:ok, connection} -> json(conn, %{data: serialize(connection)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def refresh(conn, %{"id" => id}) do
    case Backplane.refresh(id) do
      {:ok, connection} -> json(conn, %{data: serialize(connection)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def test_connection(conn, %{"id" => id}) do
    case Backplane.test(id) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, {:discovery_failed, result}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{data: result})

      {:error, :not_found} ->
        not_found(conn)

      {:error, reason} ->
        connection_error(conn, reason)
    end
  end

  defp serialize(connection) do
    last_error = safe_error(connection.last_error, connection.credential)

    %{
      id: connection.id,
      name: connection.name,
      endpoint: connection.endpoint,
      base_url: connection.base_url,
      credential_configured: connection.credential_configured,
      connection_options: connection.connection_options,
      sync_on_start: connection.sync_on_start,
      enabled: connection.enabled,
      status: connection.status,
      stale: connection.stale,
      unavailable: connection.unavailable,
      counts: connection.counts,
      artifacts: connection.artifacts,
      metadata: connection.metadata,
      last_synced_at: connection.last_synced_at,
      last_attempt_at: connection.last_attempt_at,
      last_success_at: connection.last_success_at,
      source_revision: connection.source_revision,
      last_error: last_error,
      error: last_error
    }
  end

  defp connection_error(conn, reason) when reason in [:invalid_base_url, :invalid_endpoint],
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid base URL"})

  defp connection_error(conn, reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{error: "connection not found"})

  defp safe_error(nil, _credential), do: nil

  defp safe_error(error, credential) do
    message = if is_binary(error), do: error, else: inspect(error, limit: 20)

    message =
      if is_binary(credential) and credential != "",
        do: String.replace(message, credential, "[REDACTED]"),
        else: message

    String.slice(message, 0, @max_error_length)
  end
end
