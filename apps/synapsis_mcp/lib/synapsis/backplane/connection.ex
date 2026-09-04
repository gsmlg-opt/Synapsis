defmodule Synapsis.Backplane.Connection do
  @moduledoc "Persisted Backplane capability-source connection."

  alias Synapsis.Config.Store
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary

  @store_type :backplane
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  @enforce_keys [:id, :name, :base_url]
  @derive {Inspect, except: [:credential]}
  defstruct [
    :id,
    :name,
    :base_url,
    :credential,
    :last_synced_at,
    :last_error,
    credential_configured: false,
    status: "never_synced",
    enabled: true,
    unavailable: [],
    counts: %{},
    artifacts: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    name = value(attrs, :name)
    base_url = value(attrs, :base_url)

    with :ok <- validate_name(name),
         {:ok, base_url} <- validate_url(base_url),
         {:ok, id} <- validate_id(value(attrs, :id, Ecto.UUID.generate())),
         {:ok, credential} <- load_credential(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         base_url: base_url,
         credential: credential,
         credential_configured: is_binary(credential),
         enabled: value(attrs, :enabled, true),
         status: value(attrs, :status, "never_synced"),
         last_synced_at: value(attrs, :last_synced_at),
         last_error: value(attrs, :last_error),
         unavailable: value(attrs, :unavailable, []),
         counts: value(attrs, :counts, %{}),
         artifacts: value(attrs, :artifacts, %{})
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_connection}

  def create(attrs) do
    with {:ok, connection} <- new(attrs),
         :ok <- unique_name(connection.name, connection.id),
         {:ok, _stored} <- Store.put(@store_type, to_map(connection)) do
      {:ok, connection}
    end
  end

  def get(id) when is_binary(id) do
    case Store.get(@store_type, id) do
      {:ok, attrs} -> new(attrs)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def list do
    @store_type
    |> Store.list()
    |> Enum.map(fn attrs ->
      {:ok, connection} = new(attrs)
      connection
    end)
    |> Enum.sort_by(& &1.name)
  end

  def update(%__MODULE__{} = connection, attrs) when is_map(attrs) do
    merged = Map.merge(to_map(connection), stringify_keys(attrs))

    with {:ok, updated} <- new(merged),
         :ok <- unique_name(updated.name, updated.id),
         {:ok, _stored} <- Store.put(@store_type, to_map(updated)) do
      {:ok, updated}
    end
  end

  def delete(%__MODULE__{} = connection), do: Store.delete(@store_type, connection.id)

  def redacted(%__MODULE__{} = connection), do: %{connection | credential: nil}

  defp unique_name(name, id) do
    if Enum.any?(list(), &(&1.name == name and &1.id != id)),
      do: {:error, :name_taken},
      else: :ok
  end

  defp validate_name(name) when is_binary(name) do
    if byte_size(name) <= 255 and Regex.match?(@name_pattern, name),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, String.trim_trailing(url, "/")}
    else
      {:error, :invalid_base_url}
    end
  end

  defp validate_url(_url), do: {:error, :invalid_base_url}

  defp validate_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp to_map(%__MODULE__{} = connection) do
    encrypted = encrypt_credential(connection.credential)

    connection
    |> redacted()
    |> Map.from_struct()
    |> Map.delete(:credential)
    |> Map.put(:credential_encrypted, encrypted)
    |> stringify_keys()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp load_credential(attrs) do
    cond do
      Map.has_key?(attrs, :credential) -> normalize_credential(Map.get(attrs, :credential))
      Map.has_key?(attrs, "credential") -> normalize_credential(Map.get(attrs, "credential"))
      encrypted = value(attrs, :credential_encrypted) -> decrypt_credential(encrypted)
      true -> {:ok, nil}
    end
  end

  defp normalize_credential(nil), do: {:ok, nil}

  defp normalize_credential(value) when is_binary(value) do
    if String.trim(value) == "", do: {:ok, nil}, else: {:ok, value}
  end

  defp normalize_credential(_value), do: {:error, :invalid_credential}

  defp encrypt_credential(nil), do: nil

  defp encrypt_credential(credential) do
    {:ok, encrypted} = EncryptedBinary.dump(credential)
    "enc:v1:" <> Base.encode64(encrypted)
  end

  defp decrypt_credential("enc:v1:" <> encoded) do
    with {:ok, encrypted} <- Base.decode64(encoded),
         {:ok, credential} <- EncryptedBinary.load(encrypted) do
      {:ok, credential}
    else
      _error -> {:error, :invalid_credential}
    end
  end

  defp decrypt_credential(_value), do: {:error, :invalid_credential}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
