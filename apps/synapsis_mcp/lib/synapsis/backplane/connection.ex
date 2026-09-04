defmodule Synapsis.Backplane.Connection do
  @moduledoc "Persisted Backplane capability-source connection."

  require Logger

  alias Synapsis.Config.Store
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary

  @store_type :backplane
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  @enforce_keys [:id, :name, :endpoint, :base_url]
  @derive {Inspect, except: [:credential]}
  defstruct [
    :id,
    :name,
    :endpoint,
    :base_url,
    :credential,
    :last_synced_at,
    :last_success_at,
    :last_attempt_at,
    :last_error,
    :source_revision,
    credential_configured: false,
    connection_options: %{},
    sync_on_start: true,
    status: "never_synced",
    enabled: true,
    stale: true,
    unavailable: [],
    counts: %{},
    artifacts: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    name = value(attrs, :name)
    endpoint = value(attrs, :endpoint) || value(attrs, :base_url)

    with :ok <- validate_name(name),
         {:ok, endpoint} <- validate_url(endpoint),
         {:ok, id} <- validate_id(value(attrs, :id, Ecto.UUID.generate())),
         {:ok, credential} <- load_credential(attrs),
         {:ok, connection_options} <- load_json_map(attrs, :connection_options),
         {:ok, metadata} <- load_json_map(attrs, :metadata),
         {:ok, counts} <- load_json_map(attrs, :counts),
         {:ok, artifacts} <- load_json_map(attrs, :artifacts),
         :ok <- validate_boolean(value(attrs, :sync_on_start, true), :sync_on_start),
         :ok <- validate_boolean(value(attrs, :enabled, true), :enabled),
         :ok <- validate_boolean(value(attrs, :stale, true), :stale),
         :ok <- validate_string_list(value(attrs, :unavailable, []), :unavailable) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         endpoint: endpoint,
         base_url: endpoint,
         credential: credential,
         credential_configured: is_binary(credential),
         connection_options: connection_options,
         sync_on_start: value(attrs, :sync_on_start, true),
         enabled: value(attrs, :enabled, true),
         stale: value(attrs, :stale, true),
         status: value(attrs, :status, "never_synced"),
         last_synced_at: value(attrs, :last_synced_at),
         last_success_at: value(attrs, :last_success_at),
         last_attempt_at: value(attrs, :last_attempt_at),
         last_error: value(attrs, :last_error),
         source_revision: value(attrs, :source_revision),
         unavailable: value(attrs, :unavailable, []),
         counts: counts,
         artifacts: artifacts,
         metadata: metadata
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
    |> Enum.reduce([], fn attrs, connections ->
      case new(attrs) do
        {:ok, connection} ->
          [connection | connections]

        {:error, reason} ->
          Logger.warning("backplane_connection_invalid",
            connection_id: value(attrs, :id, "unknown"),
            reason: inspect(reason)
          )

          connections
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  def update(%__MODULE__{} = connection, attrs) when is_map(attrs) do
    merged = Map.merge(to_map(connection), canonicalize_endpoint_update(attrs))

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

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, String.trim_trailing(url, "/")}
    else
      {:error, :invalid_endpoint}
    end
  end

  defp validate_url(_url), do: {:error, :invalid_endpoint}

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok
  defp validate_boolean(_value, field), do: {:error, invalid_field(field)}

  defp validate_string_list(value, _field)
       when is_list(value) and length(value) <= 100 do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, :invalid_unavailable}
  end

  defp validate_string_list(_value, _field), do: {:error, :invalid_unavailable}

  defp invalid_field(:connection_options), do: :invalid_connection_options
  defp invalid_field(:metadata), do: :invalid_metadata
  defp invalid_field(:counts), do: :invalid_counts
  defp invalid_field(:artifacts), do: :invalid_artifacts
  defp invalid_field(:sync_on_start), do: :invalid_sync_on_start
  defp invalid_field(:enabled), do: :invalid_enabled
  defp invalid_field(:stale), do: :invalid_stale

  defp canonicalize_endpoint_update(attrs) do
    attrs = stringify_keys(attrs)

    cond do
      Map.has_key?(attrs, "endpoint") -> Map.put(attrs, "base_url", attrs["endpoint"])
      Map.has_key?(attrs, "base_url") -> Map.put(attrs, "endpoint", attrs["base_url"])
      true -> attrs
    end
  end

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
    |> Map.delete(:connection_options)
    |> Map.delete(:metadata)
    |> Map.delete(:counts)
    |> Map.delete(:artifacts)
    |> Map.put(:connection_options_json, encode_json_map(connection.connection_options))
    |> Map.put(:metadata_json, encode_json_map(connection.metadata))
    |> Map.put(:counts_json, encode_json_map(connection.counts))
    |> Map.put(:artifacts_json, encode_json_map(connection.artifacts))
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

  defp load_json_map(attrs, field) do
    case value(attrs, field, :missing) do
      map when is_map(map) ->
        normalize_json_map(map, field)

      :missing ->
        decode_json_map(value(attrs, json_field(field)), field)

      _invalid ->
        {:error, invalid_field(field)}
    end
  end

  defp decode_json_map(nil, _field), do: {:ok, %{}}

  defp decode_json_map(encoded, field) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, invalid_field(field)}
    end
  end

  defp decode_json_map(_invalid, field), do: {:error, invalid_field(field)}

  defp normalize_json_map(map, field) do
    with {:ok, encoded} <- Jason.encode(map),
         {:ok, normalized} when is_map(normalized) <- Jason.decode(encoded) do
      {:ok, normalized}
    else
      _invalid -> {:error, invalid_field(field)}
    end
  rescue
    Protocol.UndefinedError -> {:error, invalid_field(field)}
  end

  defp encode_json_map(map) when map_size(map) == 0, do: nil
  defp encode_json_map(map), do: Jason.encode!(map)

  defp json_field(:connection_options), do: :connection_options_json
  defp json_field(:metadata), do: :metadata_json
  defp json_field(:counts), do: :counts_json
  defp json_field(:artifacts), do: :artifacts_json

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
