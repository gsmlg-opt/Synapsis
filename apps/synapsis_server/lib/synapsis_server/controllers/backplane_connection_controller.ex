defmodule SynapsisServer.BackplaneConnectionController do
  use SynapsisServer, :controller

  alias Synapsis.Backplane.{Client, Connection, Sync}

  @surfaces ~w(models skills tools)
  @max_error_length 500

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Connection.list(), &serialize/1)})
  end

  def create(conn, params) do
    case Connection.create(params) do
      {:ok, connection} ->
        conn |> put_status(:created) |> json(%{data: serialize(connection)})

      {:error, reason} ->
        connection_error(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, connection} <- Connection.get(id),
         {:ok, updated} <- Connection.update(connection, Map.delete(params, "id")) do
      json(conn, %{data: serialize(updated)})
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, connection} <- Connection.get(id),
         :ok <- Connection.delete(connection) do
      send_resp(conn, :no_content, "")
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def status(conn, %{"id" => id}) do
    case Sync.status(id) do
      {:ok, connection} -> json(conn, %{data: serialize(connection)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def refresh(conn, %{"id" => id}) do
    case Sync.run(id) do
      {:ok, connection} -> json(conn, %{data: serialize(connection)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  def test_connection(conn, %{"id" => id}) do
    with {:ok, connection} <- Connection.get(id) do
      results = %{
        "models" => protect(fn -> Client.fetch_models(connection) end),
        "skills" => protect(fn -> Client.list_skills(connection) end),
        "tools" => protect(fn -> Client.list_tools(connection) end)
      }

      {counts, errors} = summarize(results, connection.credential)

      if map_size(errors) == 0 do
        json(conn, %{data: %{status: "ok", counts: counts}})
      else
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: %{status: "error", counts: counts, errors: errors}})
      end
    else
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> connection_error(conn, reason)
    end
  end

  defp summarize(results, credential) do
    Enum.reduce(@surfaces, {%{}, %{}}, fn surface, {counts, errors} ->
      case results[surface] do
        {:ok, items} when is_list(items) ->
          {Map.put(counts, surface, length(items)), errors}

        {:error, reason} ->
          error = reason |> inspect() |> redact(credential) |> String.slice(0, @max_error_length)
          {counts, Map.put(errors, surface, error)}

        other ->
          error = other |> inspect() |> redact(credential) |> String.slice(0, @max_error_length)
          {counts, Map.put(errors, surface, error)}
      end
    end)
  end

  defp serialize(connection) do
    %{
      id: connection.id,
      name: connection.name,
      base_url: connection.base_url,
      credential_configured: connection.credential_configured,
      enabled: connection.enabled,
      status: connection.status,
      unavailable: connection.unavailable,
      counts: connection.counts,
      artifacts: connection.artifacts,
      last_synced_at: connection.last_synced_at,
      last_error: connection.last_error
    }
  end

  defp connection_error(conn, :invalid_base_url),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid base URL"})

  defp connection_error(conn, reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{error: "connection not found"})

  defp redact(message, credential) when is_binary(credential) and credential != "",
    do: String.replace(message, credential, "[REDACTED]")

  defp redact(message, _credential), do: message

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
