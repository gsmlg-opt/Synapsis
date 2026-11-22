defmodule Synapsis.Samgita.Devices do
  @moduledoc """
  Selected execution identities and encrypted, persistent Samgita device tokens.

  Each identity owns a separate token and server Agent mapping. Disabling preserves
  its token; forgetting retires it permanently until the operator explicitly removes
  and configures a new identity. Runtime reconnect never creates a token.
  """
  alias Synapsis.Config.Store
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary

  @fields ~w(id source_kind source_id name implementation base_url enabled forgotten agent_id connection_id generation expires_at)

  def list do
    Store.list(:samgita)
    |> Enum.filter(&(&1["kind"] == "device"))
    |> Enum.map(&public/1)
    |> Enum.sort_by(&{&1["name"], &1["id"]})
  end

  def get(id) do
    case Store.get(:samgita, id) do
      {:ok, %{"kind" => "device"} = entry} -> {:ok, public(entry)}
      _ -> {:error, :not_found}
    end
  end

  def select(source_kind, source_id, name, implementation, base_url)
      when source_kind in ["agent", "local_agent"] and
             implementation in ["synapsis", "codex", "sigma"] and
             is_binary(source_id) and is_binary(name) and is_binary(base_url) do
    with {:ok, url} <- validate_url(base_url),
         true <- byte_size(source_id) in 1..200 and byte_size(name) in 1..200 do
      Store.with_write_lock(fn ->
        existing =
          Enum.find(
            list(),
            &(&1["source_kind"] == source_kind and &1["source_id"] == source_id and
                &1["base_url"] == url)
          )

        case existing do
          %{"forgotten" => true} ->
            {:error, :device_forgotten}

          %{"id" => id} ->
            enable(id)

          nil ->
            token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            {:ok, ciphertext} = EncryptedBinary.dump(token)

            entry = %{
              "id" => Ecto.UUID.generate(),
              "kind" => "device",
              "source_kind" => source_kind,
              "source_id" => source_id,
              "name" => name,
              "implementation" => implementation,
              "base_url" => url,
              "enabled" => true,
              "forgotten" => false,
              "device_token_encrypted" => "enc:v1:" <> Base.encode64(ciphertext)
            }

            persist(entry)
        end
      end)
    else
      false -> {:error, :invalid_identity}
      error -> error
    end
  end

  def select(_, _, _, _, _), do: {:error, :invalid_identity}

  def enable(id),
    do:
      update(id, fn entry ->
        if entry["forgotten"] == true,
          do: {:error, :device_forgotten},
          else: {:ok, Map.put(entry, "enabled", true)}
      end)

  def disable(id), do: update(id, &{:ok, Map.put(&1, "enabled", false)})

  def forget(id),
    do:
      update(id, fn entry ->
        {:ok,
         entry
         |> Map.put("enabled", false)
         |> Map.put("forgotten", true)
         |> Map.delete("device_token_encrypted")}
      end)

  def resolve_token(id) do
    with {:ok, %{"kind" => "device", "forgotten" => false} = entry} <- Store.get(:samgita, id),
         "enc:v1:" <> encoded <- entry["device_token_encrypted"],
         {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, token} when is_binary(token) <- EncryptedBinary.load(ciphertext) do
      {:ok, token}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def record_connection(
        id,
        %{"id" => connection_id, "agent_id" => agent_id, "generation" => generation} = connection
      )
      when is_binary(connection_id) and is_binary(agent_id) and is_integer(generation) and
             generation > 0 do
    update(id, fn entry ->
      if entry["agent_id"] in [nil, agent_id],
        do:
          {:ok,
           Map.merge(entry, Map.take(connection, ~w(agent_id generation expires_at)))
           |> Map.put("connection_id", connection_id)},
        else: {:error, :identity_changed}
    end)
  end

  def record_connection(_, _), do: {:error, :invalid_connection}

  defp update(id, fun) do
    Store.with_write_lock(fn ->
      with {:ok, %{"kind" => "device"} = entry} <- Store.get(:samgita, id),
           {:ok, entry} <- fun.(entry),
           do: persist(entry)
    end)
  end

  defp persist(entry) do
    case Store.put(
           :samgita,
           Map.put(entry, "updated_at", DateTime.to_iso8601(DateTime.utc_now()))
         ) do
      :ok -> {:ok, public(entry)}
      {:ok, _} -> {:ok, public(entry)}
      error -> error
    end
  end

  defp public(entry), do: Map.take(entry, @fields)

  defp validate_url(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, URI.to_string(%{uri | path: nil}) |> String.trim_trailing("/")}

      _ ->
        {:error, :invalid_url}
    end
  end
end
