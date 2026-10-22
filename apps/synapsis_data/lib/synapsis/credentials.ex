defmodule Synapsis.Credentials do
  @moduledoc "Encrypted credential persistence, safe metadata and runtime secret resolution."

  alias Synapsis.{Config.Store, CredentialConfig}
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary

  def list do
    {:ok, Store.list(:credential) |> Enum.map(&metadata/1) |> Enum.sort_by(&{&1.name, &1.id})}
  end

  def get(id) do
    with {:ok, raw} <- Store.get(:credential, id), do: {:ok, metadata(raw)}
  end

  def create(attrs), do: Store.with_write_lock(fn -> create_record(attrs) end)

  def update(%CredentialConfig{id: id}, attrs), do: update(id, attrs)

  def update(id, attrs) do
    Store.with_write_lock(fn ->
      with {:ok, raw} <- Store.get(:credential, id) do
        attrs = submitted_attrs(attrs)
        key = attrs["key"]

        attrs =
          if is_nil(key) or (is_binary(key) and String.trim(key) == ""),
            do: Map.delete(attrs, "key"),
            else: attrs

        changeset = CredentialConfig.changeset(%{name: raw["name"]}, attrs)

        with {:ok, submitted} <- Ecto.Changeset.apply_action(changeset, :update) do
          updated =
            raw
            |> Map.put("name", submitted.name)
            |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now()))

          updated =
            if Map.has_key?(submitted, :key),
              do: Map.put(updated, "key_encrypted", encrypt(submitted.key)),
              else: updated

          with {:ok, stored} <- Store.replace_existing(:credential, id, updated),
               do: {:ok, metadata(stored)}
        end
      end
    end)
  end

  def delete(%CredentialConfig{id: id}), do: delete(id)

  def delete(id) do
    Store.with_write_lock(fn ->
      with {:ok, raw} <- Store.get(:credential, id),
           :ok <- Store.delete(:credential, id),
           do: {:ok, metadata(raw)}
    end)
  end

  @doc "Resolve an explicit reference, failing closed for missing or corrupt credentials."
  def resolve(id) do
    with {:ok, raw} <- Store.get(:credential, id) do
      decrypt(raw["key_encrypted"])
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  @doc "Fingerprint encrypted contents as well as the stored update version."
  def version(id) do
    with {:ok, raw} <- Store.get(:credential, id) do
      {:ok,
       :crypto.hash(:sha256, :erlang.term_to_binary({raw["key_encrypted"], raw["updated_at"]}))}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def references(id) do
    Store.list(:provider)
    |> Enum.filter(&(&1["credential_id"] == id))
    |> Enum.map(&%{id: &1["id"], name: &1["name"]})
    |> Enum.sort_by(& &1.id)
  end

  @doc "Import one legacy provider key, reusing its previous import after interrupted migration."
  def ensure_legacy_provider_key(provider_id, name, plaintext) do
    Store.with_write_lock(fn ->
      case Enum.find(Store.list(:credential), &(&1["legacy_provider_id"] == provider_id)) do
        nil -> create_record(%{name: name, key: plaintext}, provider_id)
        raw -> {:ok, metadata(raw)}
      end
    end)
  end

  defp create_record(attrs, legacy_provider_id \\ nil) do
    changeset = CredentialConfig.changeset(%{}, submitted_attrs(attrs), require_key: true)

    with {:ok, submitted} <- Ecto.Changeset.apply_action(changeset, :insert) do
      now = DateTime.to_iso8601(DateTime.utc_now())

      raw = %{
        "id" => Ecto.UUID.generate(),
        "name" => submitted.name,
        "key_encrypted" => encrypt(submitted.key),
        "inserted_at" => now,
        "updated_at" => now
      }

      raw =
        if legacy_provider_id,
          do: Map.put(raw, "legacy_provider_id", legacy_provider_id),
          else: raw

      with {:ok, stored} <- Store.put(:credential, raw), do: {:ok, metadata(stored)}
    end
  end

  defp submitted_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["name", "key"])
  end

  defp metadata(raw) do
    masked_key =
      case decrypt(raw["key_encrypted"]) do
        {:ok, secret} when byte_size(secret) > 0 ->
          if String.length(secret) > 8,
            do: "********" <> String.slice(secret, -4, 4),
            else: "********"

        _ ->
          "********"
      end

    %CredentialConfig{
      id: raw["id"],
      name: raw["name"],
      masked_key: masked_key,
      inserted_at: decode_time(raw["inserted_at"]),
      updated_at: decode_time(raw["updated_at"])
    }
  end

  defp encrypt(secret) do
    {:ok, ciphertext} = EncryptedBinary.dump(secret)
    "enc:v1:" <> Base.encode64(ciphertext)
  end

  defp decrypt("enc:v1:" <> encoded) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 <-
           EncryptedBinary.load(ciphertext) do
      {:ok, secret}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  defp decrypt(_), do: {:error, :credential_unavailable}

  defp decode_time(%DateTime{} = time), do: time

  defp decode_time(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp decode_time(_), do: nil
end
